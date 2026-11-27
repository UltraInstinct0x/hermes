"""The branch's profile ledger and the Neo box's authenticated federated read view."""

import base64
import json
import math
import re
import time


UNKNOWN = {"client_id": "unknown", "label": None, "kind": None}
STATES = ("live", "unsupported", "not_authorized", "offline", "error")
SECRET = ("secret", "sudo")


class Ledger:
    gateway_id = "mock-gateway"

    def __init__(self, backend, experimental_rpc=False):
        self.b = backend
        self.rows = {}
        self.states = {}
        self.federation = True
        self.experimental_rpc = experimental_rpc
        self.settled_at = {}
        backend["METHODS"]["client.capabilities"] = self.capabilities
        if experimental_rpc:
            backend["METHODS"].update({
                "request.list": self.list_requests, "request.history": self.history, "request.answer": self.answer,
            })
        backend["HTTP_ROUTES"].update({
            ("GET", "/bff/ledger"): lambda query, _: self.federated(query, history=False),
            ("GET", "/bff/ledger/history"): lambda query, _: self.federated(query, history=True),
            ("POST", "/api/mock/ledger-source"): self.configure,
        })

    def problem(self, code, message, data=None):
        return self.b["RPCError"](code, message, data)

    def configure(self, _query, body):
        with self.b["LOCK"]:
            if "federation" in body:
                self.federation = bool(body["federation"])
            if "profile_id" in body:
                profile, state = body["profile_id"], body.get("state")
                if profile not in self.b["PROFILES"] or state not in STATES:
                    return 400, {"detail": "Unknown source or state"}
                self.states[profile] = state
        return 200, {"ok": True}

    def profile(self, params):
        profile = params.get("profile") or "default"
        state = self.states.get(profile, "live") if profile in self.b["PROFILES"] else "not_authorized"
        if state != "live":
            code, message = {
                "unsupported": (-32601, "Method not found"),
                "not_authorized": (403, "Not authorized"),
                "offline": (503, "Source offline"),
                "error": (5310, "Ledger unavailable"),
            }[state]
            raise self.problem(code, message)
        return profile

    def capabilities(self, params):
        peer = self.b["CURRENT"].peer
        if "server_requests" in params:
            peer.answers_requests = bool(params["server_requests"])
        if "client_id" in params:
            peer.identity = {"client_id": str(params["client_id"]) or "unknown",
                             "label": params.get("label"), "kind": params.get("kind")}
        return {"server_requests": ["approval", "clarify", "secret", "sudo"],
                "declines_not_shown": True, "canonical_clarify_batch": True,
                "client_id": peer.identity["client_id"],
                "identity_source": "declared" if peer.identity["client_id"] != "unknown" else "unknown"}

    def opened(self, rid, sid, kind, params, timeout):
        runtime = self.b["RUNTIME"][sid]
        profile, session = runtime["profile"], runtime["stored"]
        now = time.time()
        choices = None
        prompt = None
        if kind == "approval":
            prompt = "\n".join(value for key in ("command", "description") if (value := params.get(key))) or None
            choices = params.get("choices")
        elif kind == "clarify":
            choices = params.get("questions") or (
                [{"qid": rid, "question": params["question"], "choices": params.get("choices") or []}]
                if "question" in params else [])
            prompt = "\n".join(q.get("question") or "" for q in choices) or None
        row = {"request_id": rid, "kind": kind, "profile": profile, "session_id": session,
               "session_key": session, "call_id": None, "bot_key": None, "state": "open",
               "prompt": prompt, "choices": choices,
               "created_at": now, "expires_at": now + timeout, "answered_at": None,
               "outcome": None, "cancel_reason": None, "answered_by": None, "answered_via": None,
               "answers": None}
        if self.states.get(profile) != "unsupported":
            row["ledger_id"] = f"v1:mock-install-0001:{profile}:{rid}"
            self.rows[row["ledger_id"]] = row
            if self.experimental_rpc:
                params.update(ledger_id=row["ledger_id"], expires_at=row["expires_at"])
        return row

    def settle(self, rid, *, result=None, by=None, via=None, state="answered", reason=None, notify=True):
        with self.b["LOCK"]:
            entry = self.b["PENDING"].pop(rid, None)
            if entry is None:
                return None
            row = entry["row"]
            kind = row["kind"]
            answer = result or {}
            answered = state == "answered"
            outcome = (answer.get("choice") if kind == "approval" else
                       "submitted" if answer.get("answers") else "skipped") if answered and kind not in SECRET else None
            if state == "expired":
                outcome = "timed_out"
            row.update(state=state, outcome=outcome, cancel_reason=reason,
                       answered_at=time.time() if answered else None, answered_by=(by or UNKNOWN) if answered else None,
                       answered_via=via if answered else None, answers=answer.get("answers") if kind == "clarify" else None)
            entry["result"] = result
            if not self.experimental_rpc and "ledger_id" in row:
                self.settled_at[row["ledger_id"]] = time.time()
        try:
            if self.experimental_rpc and answered and notify and "ledger_id" in row:
                self.b["emit"](entry["sid"], "request.resolved", self.settlement(row))
        finally:
            entry["event"].set()
        return row

    def settlement(self, row):
        return {"id": row["request_id"], "ledger_id": row["ledger_id"], "method": row["kind"],
                "kind": row["kind"], "session_id": row["session_id"], "outcome": row["outcome"],
                "choice": row["outcome"] if row["kind"] == "approval" else None,
                "answers": row["answers"], "answered_by": row["answered_by"], "at": row["answered_at"]}

    def answer(self, params):
        key, result = params.get("id"), params.get("result")
        if not isinstance(key, str) or not key or not isinstance(result, dict):
            raise self.problem(4002, "id and an object result required")
        with self.b["LOCK"]:
            profile = self.profile(params) if params.get("profile") else None
            canonical = key.startswith("v1:")
            row = self.rows.get(key) if canonical else None
            if not canonical:
                entry = self.b["PENDING"].get(key)
                row = entry["row"] if entry else None
            if canonical and row is not None and row["profile"] != (profile or "default"):
                row = None
            if row is None or row["state"] != "open":
                if not canonical:
                    return {"status": "expired"}
                raise self.problem(4065, "no longer pending", {"settlement": dict(row)} if row else None)
            entry = self.b["PENDING"][row["request_id"]]
            if "native" in entry:
                raise self.problem(4002, "this request must be answered in its chat")
            if canonical and row["kind"] not in ("approval", "clarify"):
                raise self.problem(4002, "this request must be answered in its chat")
            if row["kind"] == "approval" and ("all" in result or
                                                result.get("choice") not in self.approval_choices(entry["frame"]["params"])):
                raise self.problem(4002, "choice was not offered for this approval")
            if canonical and row["kind"] == "clarify":
                answers = result.get("answers", {})
                if not isinstance(answers, dict):
                    raise self.problem(4002, "invalid answer for this request")
                if set(answers) - {question["qid"] for question in row["choices"]}:
                    raise self.problem(4002, "unknown question id")
            sid = entry["sid"]
            settled = self.settle(row["request_id"], result=result, by=self.b["CURRENT"].peer.identity,
                                  via="request.answer", notify=False)
            settlement = self.settlement(settled) if "ledger_id" in settled else None
        if settlement:
            self.b["emit"](sid, "request.resolved", settlement)
        return {"status": "ok", "answered_by": settled["answered_by"], "settlement": dict(settled)} if canonical else {"status": "ok"}

    @staticmethod
    def approval_choices(params):
        choices = set(params.get("choices") or ("once", "session", "always", "deny"))
        if params.get("smart_denied") or params.get("allow_session") is False:
            choices.discard("session")
        if params.get("smart_denied") or params.get("allow_permanent") is False:
            choices.discard("always")
        return choices | {"deny"}

    def scoped_rows(self, profile):
        return [dict(row) for row in self.rows.values() if row["profile"] == profile]

    @staticmethod
    def listing(rows, params):
        limit = int(params["answered_limit"]) if params.get("answered_limit") is not None else 20
        opened = sorted((r for r in rows if r["state"] == "open"), key=lambda r: r["created_at"])
        closed = sorted((r for r in rows if r["state"] != "open"),
                        key=lambda r: r["answered_at"] or r["created_at"], reverse=True)
        return {"open": opened, "recent": closed[:max(0, limit)], "open_count": len(opened)}

    @staticmethod
    def page(rows, params):
        cursor, session = params.get("before"), params.get("session_id")
        kinds, states = params.get("kind"), params.get("states")
        limit = max(1, min(200, int(params["limit"]))) if params.get("limit") is not None else 50
        matching = sorted((r for r in rows if (cursor is None or r["created_at"] < float(cursor))
                           and (not session or session in (r["session_id"], r["session_key"]))
                           and (not kinds or r["kind"] == kinds) and (not states or r["state"] in states)),
                          key=lambda r: r["created_at"], reverse=True)
        return {"requests": matching[:limit], "next_before": matching[limit - 1]["created_at"] if len(matching) > limit else None}

    def list_requests(self, params):
        with self.b["LOCK"]:
            return self.listing(self.scoped_rows(self.profile(params)), params)

    def history(self, params):
        with self.b["LOCK"]:
            return self.page(self.scoped_rows(self.profile(params)), params)

    def federated(self, query, *, history):
        with self.b["LOCK"]:
            if not self.federation:
                return 404, {"detail": "Not found"}
            sources = [{"gateway_id": self.gateway_id, "profile_id": profile, "status": self.states.get(profile, "live")}
                       for profile in sorted(self.b["PROFILES"]) if self.states.get(profile) != "offline"]
            if "offline" in self.states.values():
                sources.append({"gateway_id": "mock-offline", "profile_id": None, "status": "offline"})
            rows = [dict(row, gateway_id=self.gateway_id, profile_id=profile, bot_key=f"{self.gateway_id}::{profile}")
                    for source in sources if source["status"] == "live"
                    for profile in [source["profile_id"]] for row in self.scoped_rows(profile)]
        if not history:
            page = self.listing(rows, {})
            page["open"].reverse()
            if not self.experimental_rpc:
                page.update(open=self.public_rows(page["open"]), recent=self.public_rows(page["recent"]))
                page["open_count"] = len(page["open"])
            return 200, {**page, "sources": sources}
        try:
            limit = int(query.get("limit", ["50"])[0])
            if not 1 <= limit <= 200:
                raise ValueError
            encoded = query.get("before", [None])[0]
            cursor = self.decode_cursor(encoded) if encoded is not None else {}
        except (TypeError, ValueError):
            return 400, {"error": {"code": "bad_request", "message": "Invalid ledger page parameters"}}
        matching = [row for row in rows if self.source_key(row) not in cursor or
                    (row["created_at"], row["request_id"]) < tuple(cursor[self.source_key(row)])]
        matching.sort(key=lambda row: row["request_id"], reverse=True)
        matching.sort(key=lambda row: (-row["created_at"], self.source_key(row)))
        page = matching[:limit]
        before = None
        if len(matching) > limit:
            for row in page:
                cursor[self.source_key(row)] = (row["created_at"], row["request_id"])
            before = base64.urlsafe_b64encode(json.dumps(cursor, separators=(",", ":")).encode()).decode().rstrip("=")
        return 200, {"requests": page if self.experimental_rpc else self.public_rows(page),
                     "next_before": before, "sources": sources}

    def public_rows(self, rows):
        return [dict({key: row[key] for key in ("ledger_id", "request_id", "gateway_id", "profile_id", "profile",
                                               "bot_key", "kind", "session_id", "created_at", "prompt", "choices")},
                     state=("open" if row["state"] == "open" else "unverified" if row["state"] == "lost_on_restart" else "settled"),
                     settled_at=self.settled_at.get(row["ledger_id"]), settlement_reason=row["cancel_reason"])
                for row in rows if row["kind"] in ("approval", "clarify")]

    @staticmethod
    def source_key(row):
        return json.dumps([row["gateway_id"], row["profile_id"]], separators=(",", ":"))

    @staticmethod
    def decode_cursor(encoded):
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,8192}", encoded):
            raise ValueError
        cursor = json.loads(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)))
        if not isinstance(cursor, dict) or any(
            not isinstance(position, list) or len(position) != 2 or type(position[0]) not in (int, float)
            or not math.isfinite(position[0]) or position[0] < 0 or not isinstance(position[1], str)
            or len(position[1]) > 128 for position in cursor.values()
        ):
            raise ValueError
        return cursor
