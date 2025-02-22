local M = {}
local vc_config = require("vectorcode.config")
local notify_opts = vc_config.notify_opts

---@type table<integer, VectorCode.Cache>
local CACHE = {}

---@param bufnr integer
local function kill_jobs(bufnr)
  ---@type VectorCode.Cache?
  local cache = CACHE[bufnr]
  if cache ~= nil then
    for job_pid, is_running in pairs(cache.jobs) do
      if is_running == true then
        vim.uv.kill(job_pid, 15)
      end
    end
  end
end

---@param query_message string|string[]
---@param buf_nr integer
local function async_runner(query_message, buf_nr)
  if CACHE[buf_nr] == nil or not CACHE[buf_nr].enabled then
    return
  end
  ---@type VectorCode.Cache
  local cache = CACHE[buf_nr]
  local args = {
    "query",
    "--pipe",
    "-n",
    tostring(cache.options.n_query),
  }

  if type(query_message) == "string" then
    query_message = { query_message }
  end
  vim.list_extend(args, query_message)

  if cache.options.exclude_this then
    vim.list_extend(args, { "--exclude", vim.api.nvim_buf_get_name(buf_nr) })
  end
  local job = require("plenary.job"):new({
    command = "vectorcode",
    args = args,
    detached = true,
    on_start = function()
      if cache.options.single_job then
        kill_jobs(buf_nr)
      end
    end,
    on_exit = function(self, code, signal)
      if not M.buf_is_registered(buf_nr) then
        return
      end

      CACHE[buf_nr].jobs[self.pid] = nil
      local ok, json = pcall(
        vim.json.decode,
        table.concat(self:result()) or "[]",
        { array = true, object = true }
      )
      if not ok or code ~= 0 then
        vim.schedule(function()
          if CACHE[buf_nr].options.notify then
            if signal == 15 then
              vim.notify("Retrieval aborted.", vim.log.levels.INFO, notify_opts)
            else
              vim.notify(
                "Retrieval failed:\n" .. table.concat(self:result()),
                vim.log.levels.WARN,
                notify_opts
              )
            end
          end
        end)
        return
      end
      cache = CACHE[buf_nr]
      cache.retrieval = json or {}
      vim.schedule(function()
        if cache.options.notify then
          vim.notify(
            ("Caching for buffer %d has completed."):format(buf_nr),
            vim.log.levels.INFO,
            notify_opts
          )
        end
      end)
    end,
  })
  job:start()
  ---@type VectorCode.Cache
  cache = CACHE[buf_nr]
  cache.last_run = vim.uv.clock_gettime("realtime").sec
  cache.jobs[job.pid] = true
  vim.schedule(function()
    if cache.options.notify then
      vim.notify(
        ("Caching for buffer %d has started."):format(buf_nr),
        vim.log.levels.INFO,
        notify_opts
      )
    end
  end)
end

M.register_buffer = vc_config.check_cli_wrap(
  ---@param bufnr integer?
  ---@param opts VectorCode.RegisterOpts?
  function(bufnr, opts)
    if bufnr == 0 or bufnr == nil then
      bufnr = vim.api.nvim_get_current_buf()
    end
    if M.buf_is_registered(bufnr) then
      opts = vim.tbl_deep_extend("force", opts or {}, CACHE[bufnr].options)
    end
    opts =
      vim.tbl_deep_extend("force", vc_config.get_user_config().async_opts, opts or {})

    if M.buf_is_registered(bufnr) then
      -- update the options and/or query_cb
      local cache = CACHE[bufnr]
      cache.options = vim.tbl_deep_extend("force", cache.options, opts or {})
    else
      CACHE[bufnr] = {
        enabled = true,
        retrieval = nil,
        options = opts,
        jobs = {},
      }
    end
    if opts.run_on_register then
      async_runner(opts.query_cb(bufnr), bufnr)
    end
    local group = vim.api.nvim_create_augroup(
      ("VectorCodeCacheGroup%d"):format(bufnr),
      { clear = true }
    )
    vim.api.nvim_create_autocmd(opts.events, {
      group = group,
      callback = function()
        assert(CACHE[bufnr] ~= nil, "buffer vectorcode cache not registered")
        local cache = CACHE[bufnr]
        if
          cache.last_run == nil
          or (vim.uv.clock_gettime("realtime").sec - cache.last_run) > opts.debounce
        then
          local cb = cache.options.query_cb
          async_runner(cb(bufnr), bufnr)
        end
      end,
      buffer = bufnr,
      desc = "Run query on certain autocmd",
    })
    vim.api.nvim_create_autocmd("BufWinLeave", {
      buffer = bufnr,
      desc = "Kill all running VectorCode async jobs.",
      group = group,
      callback = function()
        kill_jobs(bufnr)
      end,
    })
  end
)

M.deregister_buffer = vc_config.check_cli_wrap(
  ---@param bufnr integer?
  ---@param opts {notify:boolean}
  function(bufnr, opts)
    opts = opts or { notify = false }
    if bufnr == nil or bufnr == 0 then
      bufnr = vim.api.nvim_get_current_buf()
    end
    if M.buf_is_registered(bufnr) then
      kill_jobs(bufnr)
      vim.api.nvim_del_augroup_by_name(("VectorCodeCacheGroup%d"):format(bufnr))
      CACHE[bufnr] = nil
      if opts.notify then
        vim.notify(
          ("VectorCode Caching has been unregistered for buffer %d."):format(bufnr),
          vim.log.levels.INFO,
          notify_opts
        )
      end
    else
      vim.notify(
        ("VectorCode Caching hasn't been registered for buffer %d."):format(bufnr),
        vim.log.levels.ERROR,
        notify_opts
      )
    end
  end
)

---@param bufnr integer?
---@return boolean
M.buf_is_registered = function(bufnr)
  if bufnr == 0 or bufnr == nil then
    bufnr = vim.api.nvim_get_current_buf()
  end
  return type(CACHE[bufnr]) == "table" and CACHE[bufnr] ~= {}
end

M.query_from_cache = vc_config.check_cli_wrap(
  ---@param bufnr integer?
  ---@param opts {notify: boolean}?
  ---@return VectorCode.Result[]
  function(bufnr, opts)
    local result = {}
    if bufnr == 0 or bufnr == nil then
      bufnr = vim.api.nvim_get_current_buf()
    end
    if M.buf_is_registered(bufnr) then
      opts = vim.tbl_deep_extend(
        "force",
        { notify = CACHE[bufnr].options.notify },
        opts or {}
      )
      result = CACHE[bufnr].retrieval or {}
      if opts.notify then
        vim.schedule(function()
          vim.notify(
            ("Retrieved %d documents from cache."):format(#result),
            vim.log.levels.INFO,
            notify_opts
          )
        end)
      end
    end
    return result
  end
)

---@param bufnr integer
---@param component_cb (fun(result:VectorCode.Result):string)?
---@return {content:string, count:integer}
function M.make_prompt_component(bufnr, component_cb)
  if bufnr == 0 or bufnr == nil then
    bufnr = vim.api.nvim_get_current_buf()
  end
  if not M.buf_is_registered(bufnr) then
    return { content = "", count = 0 }
  end
  if component_cb == nil then
    ---@type fun(result:VectorCode.Result):string
    component_cb = function(result)
      return "<|file_sep|>" .. result.path .. "\n" .. result.document
    end
  end
  local final_component = ""
  local retrieval = M.query_from_cache(bufnr)
  for _, file in pairs(retrieval) do
    final_component = final_component .. component_cb(file)
  end
  return { content = final_component, count = #retrieval }
end

---@param check_item string?
---@param on_success fun(out: vim.SystemCompleted)?
---@param on_failure fun(out: vim.SystemCompleted?)?
function M.async_check(check_item, on_success, on_failure)
  if not vc_config.has_cli() then
    if on_failure ~= nil then
      on_failure()
    end
    return
  end

  check_item = check_item or "config"
  local return_code
  vim.system({ "vectorcode", "check", check_item }, {}, function(out)
    if out.code == 0 and type(on_success) == "function" then
      on_success(out)
    elseif out.code ~= 0 and type(on_failure) == "function" then
      on_failure(out)
    end
  end)
  return return_code == 0
end

---@param bufnr integer?
---@return integer
function M.buf_job_count(bufnr)
  if bufnr == nil or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  if M.buf_is_registered(bufnr) then
    return #vim.tbl_keys(CACHE[bufnr].jobs)
  else
    return 0
  end
end

---@param bufnr integer?
---@return boolean
function M.buf_is_enabled(bufnr)
  if bufnr == nil or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  return CACHE[bufnr] ~= nil and CACHE[bufnr].enabled
end

return M
