-- This module is responsible for the MR description
-- This lets the user open the description in a popup and
-- send edits to the description back to Gitlab
local Layout = require("nui.layout")
local Popup = require("nui.popup")
local job = require("gitlab.job")
local u = require("gitlab.utils")
local state = require("gitlab.state")
local miscellaneous = require("gitlab.actions.miscellaneous")
local pipeline = require("gitlab.actions.pipeline")

local M = {
  layout_visible = false,
  layout = nil,
  layout_buf = nil,
  title_bufnr = nil,
  description_bufnr = nil,
}

-- The function will render the MR description in a popup
M.summary = function()
  if M.layout_visible then
    M.layout:unmount()
    M.layout_visible = false
    return
  end

  local info_lines = state.settings.info.enabled and M.build_info_lines() or nil
  local layout, title_popup, description_popup, info_popup = M.create_layout(info_lines)

  M.layout = layout
  M.layout_buf = layout.bufnr
  M.layout_visible = true

  local function exit()
    layout:unmount()
    M.layout_visible = false
  end

  local title = state.INFO.title
  local description = state.INFO.description
  local description_lines = {}

  for line in description:gmatch("[^\n]+") do
    table.insert(description_lines, line)
    table.insert(description_lines, "")
  end

  vim.schedule(function()
    vim.api.nvim_buf_set_lines(description_popup.bufnr, 0, -1, false, description_lines)
    vim.api.nvim_buf_set_lines(title_popup.bufnr, 0, -1, false, { title })

    if info_popup then
      vim.api.nvim_buf_set_lines(info_popup.bufnr, 0, -1, false, info_lines)
      vim.api.nvim_set_option_value("modifiable", false, { buf = info_popup.bufnr })
      vim.api.nvim_set_option_value("readonly", false, { buf = info_popup.bufnr })
    end

    state.set_popup_keymaps(
      description_popup,
      M.edit_summary,
      miscellaneous.attach_file,
      { cb = exit, action_before_close = true }
    )
    state.set_popup_keymaps(title_popup, M.edit_summary, nil, { cb = exit, action_before_close = true })

    vim.api.nvim_set_current_buf(description_popup.bufnr)
  end)
end

M.build_info_lines = function()
  local info = state.INFO
  local options = {
    author = { title = "Author", content = "@" .. info.author.username .. " (" .. info.author.name .. ")" },
    created_at = { title = "Created", content = u.format_to_local(info.created_at) },
    updated_at = { title = "Updated", content = u.format_to_local(info.updated_at) },
    merge_status = { title = "Status", content = info.detailed_merge_status },
    draft = { title = "Draft", content = (info.draft and "Yes" or "No") },
    conflicts = { title = "Merge Conflicts", content = (info.has_conflicts and "Yes" or "No") },
    assignees = { title = "Assignees", content = u.make_readable_list(info.assignees, "name") },
    branch = { title = "Branch", content = info.source_branch },
    pipeline = {
      title = "Pipeline Status:",
      content = function()
        return pipeline.get_pipeline_status()
      end,
    },
  }

  local longest_used = ""
  for _, v in ipairs(state.settings.info.fields) do
    local title = options[v].title
    if string.len(title) > string.len(longest_used) then
      longest_used = title
    end
  end

  local function row_offset(row)
    local offset = string.len(longest_used) - string.len(row)
    return string.rep(" ", offset + 3)
  end

  local lines = {}
  for _, v in ipairs(state.settings.info.fields) do
    local row = options[v]
    local line = "* " .. row.title .. row_offset(row.title)
    if type(row.content) == "function" then
      local content = row.content()
      if content ~= nil then
        line = line .. row.content()
      end
    else
      line = line .. row.content
    end
    table.insert(lines, line)
  end

  return lines
end

-- This function will PUT the new description to the Go server
M.edit_summary = function()
  local description = u.get_buffer_text(M.description_bufnr)
  local title = u.get_buffer_text(M.title_bufnr):gsub("\n", " ")
  local body = { title = title, description = description }
  job.run_job("/mr/summary", "PUT", body, function(data)
    u.notify(data.message, vim.log.levels.INFO)
    state.INFO.description = data.mr.description
    state.INFO.title = data.mr.title
    M.layout:unmount()
    M.layout_visible = false
  end)
end

local base_popup_settings = {
  buf_options = {
    filetype = "markdown",
  },
  focusable = true,
  border = {
    style = "rounded",
  },
}

local details_popup_settings = {
  buf_options = {
    filetype = "markdown",
  },
  focusable = true,
  border = {
    style = "rounded",
    text = {
      top = "Details",
    },
  },
}

local description_popup_settings = {
  buf_options = {
    filetype = "markdown",
  },
  enter = true,
  focusable = true,
  border = {
    style = "rounded",
    text = {
      top = "Description",
    },
  },
}

M.create_layout = function(info_lines)
  local title_popup = Popup(base_popup_settings)
  M.title_bufnr = title_popup.bufnr
  local description_popup = Popup(description_popup_settings)
  M.description_bufnr = description_popup.bufnr
  local details_popup

  local internal_layout
  if state.settings.info.enabled then
    details_popup = Popup(details_popup_settings)
    if state.settings.info.horizontal then
      local longest_line = u.get_longest_string(info_lines)
      print(longest_line)
      internal_layout = Layout.Box({
        Layout.Box(title_popup, { size = 3 }),
        Layout.Box({
          Layout.Box(details_popup, { size = longest_line + 3 }),
          Layout.Box(description_popup, { grow = 1 }),
        }, { dir = "row", size = "100%" }),
      }, { dir = "col" })
    else
      internal_layout = Layout.Box({
        Layout.Box(title_popup, { size = 3 }),
        Layout.Box(description_popup, { grow = 1 }),
        Layout.Box(details_popup, { size = #info_lines }),
      }, { dir = "col" })
    end
  else
    internal_layout = Layout.Box({
      Layout.Box(title_popup, { size = 3 }),
      Layout.Box(description_popup, { grow = 1 }),
    }, { dir = "col" })
  end

  local layout = Layout({
    position = "50%",
    relative = "editor",
    size = {
      width = "95%",
      height = "95%",
    },
  }, internal_layout)

  layout:mount()

  return layout, title_popup, description_popup, details_popup
end

return M
