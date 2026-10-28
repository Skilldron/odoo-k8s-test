from odoo.tests import TransactionCase, tagged


@tagged("post_install", "-at_install")
class TestDevSampleNoteUser(TransactionCase):
    def test_assigned_to_creator(self):
        note = self.env["dev.sample.note"].create({"name": "Mine"})
        self.assertEqual(note.user_id, self.env.user)
