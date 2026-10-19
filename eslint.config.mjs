// ESLint (flat config) for the JS of the Odoo addons (ES modules, OWL).
import js from "@eslint/js";
import globals from "globals";

export default [
    {
        ignores: ["node_modules/**", "vendor/**", "**/static/lib/**"],
    },
    js.configs.recommended,
    {
        files: ["addons/**/*.js"],
        languageOptions: {
            ecmaVersion: "latest",
            sourceType: "module",
            globals: {
                ...globals.browser,
                odoo: "readonly",
                owl: "readonly",
                luxon: "readonly",
            },
        },
        rules: {
            "no-unused-vars": ["warn", {args: "none"}],
        },
    },
];
