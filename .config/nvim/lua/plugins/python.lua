-- Python: pyright (lsp.lua) does types/completion; ruff does linting and
-- formatting.  Which lint rules apply is per-repo config, not editor config:
-- [tool.ruff.lint] in the repo's pyproject.toml (select = ["E", "W", "F"]
-- matches flake8's rule set).
return {
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      vim.list_extend(opts.ensure_installed, { "ruff" })
    end,
  },
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        ruff = {
          -- pyright owns hover; ruff's hover would shadow it with rule docs
          on_attach = function(client)
            client.server_capabilities.hoverProvider = false
          end,
        },
      },
    },
  },
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = {
        python = { "ruff_format" },
      },
    },
  },
}
