#ifndef SERIAL_MILESTONES_H
#define SERIAL_MILESTONES_H

#include <cstdint>
#include <string>
#include <vector>

// Match the first occurrence on UART TX, then sample at the end of that cycle.
// Reporting can wait for a line boundary without moving the timestamp.
class SerialMilestones
{
public:
  struct Record
  {
    std::string text, window;
    uint64_t cycles = 0, insts = 0;
    bool matched = false, sampled = false, reported = false;
  };

  bool add(const std::string &text)
  {
    if (text.empty() || text.find_first_of("\r\n") != std::string::npos)
      return false;
    for (const auto &record : records_)
      if (record.text == text)
        return true;
    Record record;
    record.text = text;
    records_.push_back(record);
    return true;
  }

  void feed(char ch)
  {
    for (auto &record : records_)
    {
      if (record.matched)
        continue;
      record.window.push_back(ch);
      if (record.window.size() > record.text.size())
        record.window.erase(0, record.window.size() - record.text.size());
      record.matched = record.window == record.text;
    }
  }

  template <typename Report>
  void sample(uint64_t cycles, uint64_t insts, bool can_report, Report report)
  {
    for (auto &record : records_)
    {
      if (record.matched && !record.sampled)
      {
        record.cycles = cycles;
        record.insts = insts;
        record.sampled = true;
      }
      if (can_report && record.sampled && !record.reported)
      {
        report(record);
        record.reported = true;
      }
    }
  }

private:
  std::vector<Record> records_;
};

#endif
