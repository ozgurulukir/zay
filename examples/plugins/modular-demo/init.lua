-- init.lua — Main plugin entrypoint requiring submodules
local helpers = nova.require("./helpers")
local formatter = nova.require("formatter")

nova.register_tool({
  name = "calculate_stats",
  description = "Calculate and format statistics for a list of comma-separated numbers",
  parameters = {
    numbers = {
      type = "string",
      description = "Comma-separated list of numbers (e.g. '10, 20, 30')",
    },
  },
  handler = function(params)
    local list = {}
    for item in string.gmatch(params.numbers or "", "([^,]+)") do
      local num = tonumber(string.match(item, "^%s*(.-)%s*$"))
      if num then
        table.insert(list, num)
      end
    end

    local stats = helpers.calculate_stats(list)
    return formatter.format_stats(stats)
  end,
})
