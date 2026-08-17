-- formatter/init.lua — Directory submodule loaded via nova.require("formatter")
local Formatter = {}

function Formatter.format_stats(stats)
  return string.format("Count: %d | Sum: %.2f | Average: %.2f", stats.count, stats.sum, stats.average)
end

return Formatter
