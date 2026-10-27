from datetime import timedelta

from odoo import fields
from odoo.tests import TransactionCase, tagged


@tagged("post_install", "-at_install")
class TestDevSampleNote(TransactionCase):
    def test_is_late(self):
        yesterday = fields.Date.today() - timedelta(days=1)
        note = self.env["dev.sample.note"].create(
            {"name": "Late", "deadline": yesterday}
        )
        self.assertTrue(note.is_late)

        note.action_mark_done()
        self.assertTrue(note.done)
        self.assertFalse(note.is_late)

    def test_not_late_without_deadline(self):
        note = self.env["dev.sample.note"].create({"name": "No deadline"})
        self.assertFalse(note.is_late)

    def test_copy_is_not_done(self):
        note = self.env["dev.sample.note"].create({"name": "Done"})
        note.action_mark_done()
        self.assertFalse(note.copy().done)
