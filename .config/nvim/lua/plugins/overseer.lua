-- Task runner. Overseer already ships a builtin `just` template that turns each
-- recipe into a task and each recipe argument into a prompt. We disable that
-- builtin and register our own variant that is identical except it renders a
-- parameter as a *dropdown* (enum) when the justfile defines its choices.
--
-- Convention: a recipe parameter `foo` becomes a dropdown when the justfile has
-- a variable `foo_choices` (explicit) or `foos` (plural fallback):
--   products := "base mj mt nt"
--   build product: ...            # `product` -> dropdown of base/mj/mt/nt
-- No `_choices` variable => the parameter stays a free-text input, exactly like
-- the builtin.

local function is_justfile(name)
  name = name:lower()
  return name == "justfile" or name == ".justfile"
end

-- Parse `just --evaluate` output (`name := "value"` per line) into a table.
local function parse_vars(stdout)
  local vars = {}
  for line in vim.gsplit(stdout or "", "\n", { trimempty = true }) do
    local name, val = line:match('^(%S+)%s*:=%s*"(.*)"%s*$')
    if name then
      vars[name] = val
    end
  end
  return vars
end

-- Choices for a parameter, or nil to keep it free-text. Prefers `<name>_choices`,
-- falls back to a naive plural `<name>s`.
local function choices_for(vars, name)
  local raw = vars[name .. "_choices"] or vars[name .. "s"]
  if not raw or raw == "" then
    return nil
  end
  return vim.split(raw, " ", { trimempty = true })
end

-- Build the command for a recipe. `fixed` holds parameters already chosen (via
-- the task name); anything else comes from the prompted `params`.
local function build_cmd(recipe, cwd, fixed, params)
  local cmd = { "just", recipe.namepath }
  for _, param in ipairs(recipe.parameters) do
    local v = fixed[param.name]
    if v == nil then
      v = params[param.name]
    end
    if v and v ~= "" then
      if type(v) == "table" then
        vim.list_extend(cmd, v)
      else
        table.insert(cmd, v)
      end
    end
  end
  return { cmd = cmd, cwd = cwd }
end

local function add_recipes(task_list, cwd, recipes, vars)
  for _, recipe in pairs(recipes) do
    if not recipe.private then
      -- Singular params that declare choices get expanded into separate task
      -- entries (a real menu); every other param stays a prompted form field.
      local choice_params = {}
      for _, param in ipairs(recipe.parameters) do
        local choices = param.kind == "singular" and choices_for(vars, param.name)
        if choices then
          table.insert(choice_params, { name = param.name, choices = choices })
        end
      end

      -- Cartesian product of all choice params -> one task per combination.
      local combos = { { fixed = {}, suffix = "" } }
      for _, cp in ipairs(choice_params) do
        local expanded = {}
        for _, combo in ipairs(combos) do
          for _, choice in ipairs(cp.choices) do
            local fixed = vim.tbl_extend("force", {}, combo.fixed)
            fixed[cp.name] = choice
            table.insert(expanded, { fixed = fixed, suffix = combo.suffix .. " " .. choice })
          end
        end
        combos = expanded
      end

      for _, combo in ipairs(combos) do
        -- Remaining (non-fixed) params still prompt as free text / list.
        local params_defn = {}
        for _, param in ipairs(recipe.parameters) do
          if combo.fixed[param.name] == nil then
            params_defn[param.name] = {
              default = param.default,
              type = param.kind == "singular" and "string" or "list",
              delimiter = " ",
            }
          end
        end

        table.insert(task_list, {
          name = string.format("just %s%s", recipe.namepath, combo.suffix),
          desc = recipe.doc,
          params = params_defn,
          builder = function(params)
            return build_cmd(recipe, cwd, combo.fixed, params)
          end,
        })
      end
    end
  end
end

local just_provider = {
  name = "just",
  cache_key = function(opts)
    return vim.fs.find(is_justfile, { upward = true, path = opts.dir })[1]
  end,
  generator = function(opts, cb)
    if vim.fn.executable("just") == 0 then
      return 'Command "just" not found'
    end
    local justfile = vim.fs.find(is_justfile, { upward = true, path = opts.dir })[1]
    if not justfile then
      return "No justfile found"
    end
    local cwd = vim.fs.dirname(justfile)
    vim.system(
      { "just", "--unstable", "--dump", "--dump-format", "json" },
      { cwd = cwd, text = true },
      function(dump)
        if dump.code ~= 0 then
          return cb(dump.stderr or dump.stdout or "Error running 'just'")
        end
        local ok, data = pcall(vim.json.decode, dump.stdout, { luanil = { object = true } })
        if not ok then
          return cb("just produced invalid json")
        end
        -- Second pass: variable values, so we can turn params into dropdowns.
        vim.system({ "just", "--evaluate" }, { cwd = cwd, text = true }, function(ev)
          local vars = ev.code == 0 and parse_vars(ev.stdout) or {}
          local ret = {}
          add_recipes(ret, cwd, data.recipes or {}, vars)
          for _, module in pairs(data.modules or {}) do
            add_recipes(ret, cwd, module.recipes or {}, vars)
          end
          -- `pairs()` over the dump is hash order, so sort for a stable,
          -- predictable list (matches `just --list`).
          table.sort(ret, function(a, b)
            return a.name < b.name
          end)
          cb(ret)
        end)
      end
    )
  end,
}

return {
  {
    "stevearc/overseer.nvim",
    cmd = {
      "OverseerOpen",
      "OverseerClose",
      "OverseerToggle",
      "OverseerRun",
      "OverseerRunCmd",
      "OverseerInfo",
      "OverseerBuild",
      "OverseerQuickAction",
      "OverseerTaskAction",
      "OverseerClearCache",
    },
    keys = {
      { "<leader>o", "", desc = "+overseer" },
      { "<leader>oo", "<cmd>OverseerToggle<cr>", desc = "Toggle task list" },
      { "<leader>or", "<cmd>OverseerRun<cr>", desc = "Run task" },
      { "<leader>oc", "<cmd>OverseerRunCmd<cr>", desc = "Run command" },
      { "<leader>oa", "<cmd>OverseerQuickAction<cr>", desc = "Quick action" },
      { "<leader>oi", "<cmd>OverseerInfo<cr>", desc = "Info" },
      { "<leader>ob", "<cmd>OverseerBuild<cr>", desc = "Build task" },
    },
    opts = {
      -- Replace the builtin just template with our dropdown-aware variant below.
      disable_template_modules = { "overseer.template.just" },
    },
    config = function(_, opts)
      local overseer = require("overseer")
      overseer.setup(opts)
      overseer.register_template(just_provider)
    end,
  },
}
