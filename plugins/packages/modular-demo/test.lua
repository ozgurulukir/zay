local test = test_runner

-- Mock helpers for standalone test execution
local helpers = {
  calculate_stats = function(numbers)
    local sum = 0
    local count = #numbers
    if count == 0 then
      return { count = 0, sum = 0, average = 0 }
    end
    for _, n in ipairs(numbers) do
      sum = sum + n
    end
    return { count = count, sum = sum, average = sum / count }
  end
}

local formatter = {
  format_stats = function(stats)
    return string.format("Count: %d | Sum: %.2f | Average: %.2f", stats.count, stats.sum, stats.average)
  end
}

test.describe("modular-demo plugin", function()
  test.it("calculates statistics accurately", function()
    local stats = helpers.calculate_stats({ 10, 20, 30 })
    test.assert.equal(3, stats.count, "expected count 3")
    test.assert.equal(60, stats.sum, "expected sum 60")
    test.assert.equal(20, stats.average, "expected average 20")
  end)

  test.it("handles empty number lists", function()
    local stats = helpers.calculate_stats({})
    test.assert.equal(0, stats.count, "expected count 0")
    test.assert.equal(0, stats.sum, "expected sum 0")
    test.assert.equal(0, stats.average, "expected average 0")
  end)

  test.it("formats statistics correctly", function()
    local formatted = formatter.format_stats({ count = 3, sum = 60, average = 20 })
    test.assert.equal("Count: 3 | Sum: 60.00 | Average: 20.00", formatted, "expected formatted string")
  end)
end)

return test.run()
