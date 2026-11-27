from test_sending import MockCase, Socket, TOKEN


class NativeRequestAnswers(MockCase):
    backend_args = ("--session-authority", "--hermes-version", "0.23.4")

    def open_chat(self, **create):
        chat, runtime, session = super().open_chat(**create)
        chat.sock.settimeout(5)
        return chat, runtime, session

    def test_only_the_exact_subscribed_approval_is_settled(self):
        chat, runtime, session = self.open_chat()
        self.assertIn("result", self.submit(chat, runtime, "native approve", submission_id="native-approval"))
        prompt = self.until_event(chat, "approval.request")
        phone = Socket(self.port, f"/api/ws?token={TOKEN}")
        self.addCleanup(phone.close)
        params = dict(session_id=session, execution_generation=prompt["execution_generation"],
                      prompt_id=prompt["prompt_id"], choice="once")
        error = self.rpc(phone, "approval.respond", params)["error"]
        self.assertEqual(error["data"]["reason"], "permission_denied")
        snapshot = self.rpc(phone, "session.resume", {"session_id": session})["result"]
        self.assertEqual(snapshot["prompts"], [prompt])
        self.assertEqual(snapshot["open_requests"], [])
        self.assertEqual(snapshot["session_id"], session)
        self.assertEqual(snapshot["execution_generation"], prompt["execution_generation"])
        invalid = self.rpc(phone, "approval.respond", dict(params, choice="always"))
        self.assertEqual(invalid["error"]["data"]["reason"], "invalid_params")
        stale = self.rpc(phone, "approval.respond", dict(params, execution_generation=-1))
        self.assertEqual(stale["error"]["data"]["reason"], "stale_generation")
        wrong_kind = self.rpc(phone, "clarify.respond", {k: v for k, v in dict(params, answer="x").items() if k != "choice"})
        self.assertEqual(wrong_kind["error"]["data"]["reason"], "invalid_params")
        wrong_id = self.rpc(phone, "approval.respond", dict(params, prompt_id="different"))["result"]
        self.assertEqual(wrong_id, {"status": "already_resolved", "prompt_id": "different"})
        receipt = self.rpc(phone, "approval.respond", params)["result"]
        self.assertEqual(receipt, {"status": "resolved", "prompt_id": prompt["prompt_id"]})
        self.assertEqual(self.rpc(phone, "approval.respond", params)["result"],
                         {"status": "already_resolved", "prompt_id": prompt["prompt_id"]})
        self.assertEqual(self.rpc(phone, "session.resume", {"session_id": session})["result"]["prompts"], [])

    def test_native_clarify_takes_a_string_without_question_id(self):
        chat, runtime, session = self.open_chat()
        self.assertIn("result", self.submit(chat, runtime, "native clarify", submission_id="native-clarify"))
        prompt = self.until_event(chat, "clarify.request")
        self.rpc(chat, "session.resume", {"session_id": session})
        params = dict(session_id=session, execution_generation=prompt["execution_generation"],
                      prompt_id=prompt["prompt_id"], answer="Custom report")
        extra = self.rpc(chat, "clarify.respond", dict(params, question_id="other"))
        self.assertEqual(extra["error"]["data"]["reason"], "invalid_params")
        self.assertEqual(self.rpc(chat, "clarify.respond", params)["result"]["status"], "resolved")

    def test_empty_native_clarify_answer_settles_the_skipped_question(self):
        chat, runtime, session = self.open_chat()
        self.assertIn("result", self.submit(chat, runtime, "native clarify", submission_id="skip-clarify"))
        prompt = self.until_event(chat, "clarify.request")
        self.rpc(chat, "session.resume", {"session_id": session})
        params = dict(session_id=session, execution_generation=prompt["execution_generation"],
                      prompt_id=prompt["prompt_id"], answer="")
        self.assertEqual(self.rpc(chat, "clarify.respond", params)["result"],
                         {"status": "resolved", "prompt_id": prompt["prompt_id"]})
        self.assertEqual(self.rpc(chat, "session.resume", {"session_id": session})["result"]["prompts"], [])
