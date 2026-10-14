# Modules achetés (Odoo Apps Store)

Ce dossier est dans l'`addons_path` (avant les modules OCA et le cœur d'Odoo). Il est
exclu du lint et du formatage : c'est le code de l'éditeur.

- Un dossier par module, **décompressé tel quel**, jamais modifié. Pour adapter un
  module, créer un module `addons/<module>_custom` qui en hérite.
- Mise à jour : remplacer le dossier par la nouvelle version, un commit dédié
  (`vendor: <module> 1.2 → 1.3`) pour relire le diff de l'éditeur.
- Dépendances Python (`external_dependencies` du manifest) : les reporter dans
  `requirements.txt`, avec le nom du paquet pip.
- Licence (souvent OPL-1) : les modules ne vont que dans des dépôts **privés**, jamais
  dans le dépôt modèle.

Tenir à jour la liste ci-dessous.

| Module | Éditeur | Version | Licence | Source / date d'achat |
| ------ | ------- | ------- | ------- | --------------------- |
