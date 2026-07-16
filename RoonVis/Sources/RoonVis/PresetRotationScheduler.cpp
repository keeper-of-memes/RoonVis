#include "PresetRotationScheduler.h"

namespace RoonVis
{

namespace
{

std::string TrimWhitespace(const std::string &value)
{
    const char *whitespace = " \t\r\n";
    const size_t first = value.find_first_not_of(whitespace);
    if (first == std::string::npos)
    {
        return {};
    }
    const size_t last = value.find_last_not_of(whitespace);
    return value.substr(first, last - first + 1);
}

}  // namespace

std::vector<std::string> ParseFixedRotationList(const std::string &value)
{
    // Delimiter: '|' when the value contains one, else ','. Milkdrop preset
    // filenames frequently contain commas (which silently fragmented
    // comma-joined lists); no filename in the pack contains a pipe, so
    // pipe-joined lists pass arbitrary names losslessly. Comma stays the
    // default for backwards compatibility with existing runbooks.
    const char delimiter = value.find('|') != std::string::npos ? '|' : ',';
    std::vector<std::string> filenames;
    size_t start = 0;
    while (start <= value.size())
    {
        size_t split = value.find(delimiter, start);
        if (split == std::string::npos)
        {
            split = value.size();
        }
        std::string entry = TrimWhitespace(value.substr(start, split - start));
        if (!entry.empty())
        {
            filenames.push_back(std::move(entry));
        }
        start = split + 1;
    }
    return filenames;
}

std::vector<size_t> ResolveFixedRotationIndexes(const std::vector<std::string> &filenames,
                                                const std::vector<std::string> &presetPaths)
{
    std::vector<size_t> indexes;
    indexes.reserve(filenames.size());
    for (const std::string &filename : filenames)
    {
        for (size_t index = 0; index < presetPaths.size(); index++)
        {
            const std::string &path = presetPaths[index];
            const size_t slash = path.find_last_of('/');
            const size_t nameStart = slash == std::string::npos ? 0 : slash + 1;
            if (path.compare(nameStart, std::string::npos, filename) == 0)
            {
                indexes.push_back(index);
                break;
            }
        }
    }
    return indexes;
}

PresetRotationScheduler::PresetRotationScheduler(unsigned skipCap)
    : skipCap_(skipCap)
{
}

void PresetRotationScheduler::NoteSwitchRequested()
{
    failureSkips_ = 0;
}

PresetRotationScheduler::FailureAction PresetRotationScheduler::NoteSwitchFailed(bool reverting,
                                                                                bool hasLastGood)
{
    ++failuresTotal_;
    if (failureSkips_ >= skipCap_)
    {
        // Skip cap reached. If a last-good revert is already in flight, this is the
        // revert's own re-entrant failure — give up and hold the confirmed preset.
        if (reverting)
        {
            return FailureAction::HoldConfirmed;
        }
        return hasLastGood ? FailureAction::RevertToLastGood : FailureAction::HoldConfirmed;
    }
    ++failureSkips_;
    return FailureAction::SkipToNext;
}

}  // namespace RoonVis
