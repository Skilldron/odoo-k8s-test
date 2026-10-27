from odoo import api, fields, models


class DevSampleNote(models.Model):
    _name = "dev.sample.note"
    _description = "Dev Sample Note"
    _order = "deadline, id"

    name = fields.Char(required=True)
    description = fields.Text()
    deadline = fields.Date()
    done = fields.Boolean(copy=False)
    is_late = fields.Boolean(compute="_compute_is_late")
    priority = fields.Selection([("0", "Normal"), ("1", "High")], default="0")

    @api.depends("deadline", "done")
    def _compute_is_late(self):
        today = fields.Date.context_today(self)
        for note in self:
            note.is_late = bool(
                note.deadline and not note.done and note.deadline < today
            )

    def action_mark_done(self):
        self.done = True
