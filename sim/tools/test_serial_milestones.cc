#include "serial_milestones.h"

#include <cassert>
#include <vector>

int main()
{
  SerialMilestones milestones;
  assert(!milestones.add(""));
  assert(!milestones.add("two\nlines"));
  assert(!milestones.add("carriage\rreturn"));
  assert(milestones.add("init"));
  assert(milestones.add("init")); // Duplicate options do not duplicate reports.
  assert(milestones.add("nit"));  // Overlapping patterns can match the same byte.
  std::vector<SerialMilestones::Record> reports;
  auto report = [&](const SerialMilestones::Record &record) { reports.push_back(record); };
  for (char ch : std::string("inXinit"))
    milestones.feed(ch);
  milestones.sample(123, 45, false, report);
  assert(reports.empty());
  milestones.feed('\n');
  milestones.sample(456, 90, true, report);
  assert(reports.size() == 2);
  for (const auto &record : reports)
    assert(record.cycles == 123 && record.insts == 45);
  for (char ch : std::string("init\n"))
    milestones.feed(ch);
  milestones.sample(789, 100, true, report);
  assert(reports.size() == 2);
  assert(milestones.add("login:"));
  for (char ch : std::string("login:"))
    milestones.feed(ch);
  milestones.sample(999, 200, true, report); // Forced flush without a newline.
  assert(reports.size() == 3 && reports.back().cycles == 999);
}
