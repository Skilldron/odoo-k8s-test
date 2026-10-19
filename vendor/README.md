# Purchased modules (Odoo Apps Store)

This folder is in the `addons_path` (before the OCA modules and the Odoo core). It is
excluded from lint and formatting: it is the vendor's code.

- One folder per module, **unzipped as is**, never modified. To adapt a module, create
  an `addons/<module>_custom` module that inherits from it.
- Update: replace the folder with the new version, in a dedicated commit
  (`vendor: <module> 1.2 → 1.3`) to review the vendor's diff.
- Python dependencies (`external_dependencies` of the manifest): add them to
  `requirements.txt`, with the pip package name.
- License (often OPL-1): these modules only go to **private** repositories, never to the
  template repository.

Keep the list below up to date.

| Module | Vendor | Version | License | Source / purchase date |
| ------ | ------ | ------- | ------- | ---------------------- |
