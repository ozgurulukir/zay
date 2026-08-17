-- helpers.lua — Submodule loaded via nova.require("./helpers")
local Helpers = {}

function Helpers.calculate_stats(numbers)
  local sum = 0
  local count = #numbers
  if count == 0 then
    return { count = 0, sum = 0, average = 0 }
  end
  for _, n in ipairs(numbers) do
    sum = sum + n
  end
  return {
    count = count,
    sum = sum,
    average = sum / count,
  }
end

return Helpers
