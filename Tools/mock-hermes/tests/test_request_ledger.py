"""Profile and federated ledger contracts, using real mock sockets and HTTP requests."""

import concurrent.futures
import threading

from test_sending import MockCase, Socket, TOKEN


class RequestLedger(MockCase):
    def box(self, path):
        return self.call("GET", path, headers={"Cookie": f"bff_device={TOKEN}"})

    def device(self, client_id, ws=None):
        if ws is None:
            ws = Socket(self.port, f"/api/ws?token={TOKEN}")
            self.addCleanup(ws.close)
            ws.sock.settimeout(20)
        result = self.rpc(ws, "client.capabilities", {
            "server_requests": True, "client_id": client_id, "label": client_id, "kind": "ios",
        })["result"]
        self.assertEqual(result["client_id"], client_id)
        return ws

    def approval(self, profile="default"):
        ws, runtime, stored = self.open_chat(profile=profile)
        self.device("chat device", ws)
        self.submit(ws, runtime, "approve")
        frame = self.until_request(ws, "approval")
        return ws, stored, frame

    def source(self, profile, state):
        status, _ = self.call("POST", "/api/mock/ledger-source", {"profile_id": profile, "state": state})
        self.assertEqual(status, 200)
        self.addCleanup(self.call, "POST", "/api/mock/ledger-source", {"profile_id": profile, "state": "live"})

    @staticmethod
    def answer_payload(ledger_id, choice, profile="default"):
        return {"id": ledger_id, "profile": profile, "result": {"choice": choice}}

    def test_two_identical_prompts_race_exactly_one_wins_without_attached_chat(self):
        chat, first_session, first = self.approval()
        _, second_session, second = self.approval()
        first_id, second_id = [frame["params"]["ledger_id"] for frame in (first, second)]
        self.assertEqual(first["params"]["command"], second["params"]["command"])
        self.assertNotEqual(first_id, second_id)

        devices = [self.device(label) for label in ("phone 1", "phone 2")]
        snapshot = self.rpc(devices[0], "request.list", {"answered_limit": 0})["result"]
        self.assertEqual({r["ledger_id"]: r["session_id"] for r in snapshot["open"]},
                         {first_id: first_session, second_id: second_session})
        for row in snapshot["open"]:
            if row["ledger_id"] == first_id:
                self.assertEqual(row["expires_at"], first["params"]["expires_at"])
        status, merged = self.box("/bff/ledger")
        self.assertEqual(status, 200)
        self.assertEqual(merged["open_count"], 2)
        self.assertEqual({(r["ledger_id"], r["gateway_id"], r["profile_id"]) for r in merged["open"]},
                         {(first_id, "mock-gateway", "default"), (second_id, "mock-gateway", "default")})
        status, page = self.box("/bff/ledger/history?limit=1")
        self.assertEqual(status, 200)
        self.assertEqual([(r["ledger_id"], r["state"]) for r in page["requests"]], [(second_id, "open")])

        refused = self.rpc(devices[0], "request.answer", self.answer_payload(first_id, "invalid"))
        self.assertEqual(refused["error"]["code"], 4002)
        barrier = threading.Barrier(2)

        def race(ws, choice):
            barrier.wait(timeout=10)
            ws.send({"jsonrpc": "2.0", "id": "race", "method": "request.answer",
                     "params": self.answer_payload(first_id, choice)})
            while (reply := ws.recv()) is not None:
                if reply.get("id") == "race":
                    return reply
            self.fail("the socket closed without the race answer")

        with concurrent.futures.ThreadPoolExecutor() as pool:
            answers = [pool.submit(race, ws, choice) for ws, choice in zip(devices, ("once", "deny"))]
            replies = [answer.result(timeout=20) for answer in answers]
        self.assertEqual(sum("result" in r for r in replies), 1, replies)
        winner, = [r["result"] for r in replies if "result" in r]
        loser, = [r["error"] for r in replies if "error" in r]
        self.assertEqual(winner["status"], "ok")
        self.assertEqual(loser["code"], 4065)
        self.assertEqual(loser["message"], "no longer pending")
        resolved = self.until_event(chat, "request.resolved")
        self.assertEqual(winner["settlement"], loser["data"]["settlement"])
        self.assertEqual(winner["settlement"]["outcome"], resolved["outcome"])
        self.assertEqual(resolved["ledger_id"], first_id)
        self.assertEqual(resolved["answered_by"], winner["answered_by"])
        self.assertEqual(resolved["answered_by"]["kind"], "ios")

        remaining = self.rpc(devices[0], "request.list", {})["result"]["open"]
        self.assertEqual([row["ledger_id"] for row in remaining], [second_id])
        self.rpc(devices[0], "request.answer", self.answer_payload(second_id, "deny"))
        status, page = self.box("/bff/ledger/history?limit=1")
        self.assertEqual(status, 200)
        self.assertEqual(page["requests"][0]["ledger_id"], second_id)
        self.assertIsInstance(page["next_before"], str)
        status, page = self.box(f"/bff/ledger/history?limit=1&before={page['next_before']}")
        self.assertEqual(status, 200)
        self.assertEqual(page["requests"][0]["ledger_id"], first_id)

    def test_external_winner_and_restart_report_different_outcomes(self):
        ws, _, first = self.approval()
        first_id = first["params"]["ledger_id"]
        external = {"client_id": "telegram", "label": "Telegram", "kind": "telegram"}
        status, _ = self.call("POST", "/api/mock/answer-elsewhere", {
            "ledger_id": first_id, "result": {"choice": "deny"}, "answered_by": external,
        })
        self.assertEqual(status, 200)
        late = self.rpc(ws, "request.answer", self.answer_payload(first_id, "once"))
        self.assertEqual(late["error"]["data"]["settlement"]["answered_by"], external)
        _, _, second = self.approval()
        second_id = second["params"]["ledger_id"]
        self.assertEqual(self.call("POST", "/api/mock/restart-gateway", {})[0], 200)
        device = self.device("after restart")
        history = self.rpc(device, "request.history", {"states": ["lost_on_restart"]})["result"]
        self.assertEqual([r["ledger_id"] for r in history["requests"]], [second_id])
        self.assertIsNone(history["requests"][0]["answered_by"])
        late = self.rpc(device, "request.answer", self.answer_payload(second_id, "once"))
        self.assertEqual(late["error"]["message"], "no longer pending")
        self.assertEqual(late["error"]["data"]["settlement"]["state"], "lost_on_restart")
        self.assertIsNone(late["error"]["data"]["settlement"]["answered_by"])
        unknown = self.rpc(device, "request.answer", self.answer_payload("v1:unknown:default:unknown", "once"))
        self.assertEqual(unknown["error"]["code"], 4065)
        self.assertNotIn("data", unknown["error"])

    def test_source_refusals_and_resume_fallback(self):
        for profile, state in [("default", "unsupported"), ("researcher", "offline"), ("writer", "not_authorized")]:
            self.source(profile, state)
        ws, stored, frame = self.approval()
        self.assertNotIn("ledger_id", frame["params"])
        for profile, code in [("default", -32601), ("researcher", 503), ("writer", 403)]:
            self.assertEqual(self.rpc(ws, "request.list", {"profile": profile})["error"]["code"], code)
        snapshot = self.rpc(ws, "session.resume", {"session_id": stored})["result"]
        self.assertEqual([r["id"] for r in snapshot["open_requests"]], [frame["id"]])
        ws.send({"jsonrpc": "2.0", "id": frame["id"], "result": {"choice": "deny"}})
        status, merged = self.box("/bff/ledger")
        self.assertEqual(status, 200)
        states = {s["profile_id"]: s["status"] for s in merged["sources"]}
        self.assertEqual([states[p] for p in ("default", None, "writer")],
                         ["unsupported", "offline", "not_authorized"])
        self.assertEqual(self.call("GET", "/bff/ledger", headers={"Cookie": "bff_device=wrong", "Authorization": ""})[0], 401)
        self.assertEqual(self.box("/bff/ledger/history?before=bogus")[0], 400)
        self.call("POST", "/api/mock/ledger-source", {"federation": False})
        self.addCleanup(self.call, "POST", "/api/mock/ledger-source", {"federation": True})
        self.assertEqual(self.box("/bff/ledger")[0], 404)
