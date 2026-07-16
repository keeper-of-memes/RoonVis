#include "LegacyNameMigration.h"

#include <algorithm>
#include <cctype>
#include <string_view>

namespace RoonVis
{
namespace
{

// Hand-rolled flat-object JSON parsing, mirroring PresetBlocklist.cpp: no external
// dependency, tolerant of whitespace, strict all-or-nothing failure.

void SkipWhitespace(std::string_view text, size_t &offset)
{
    while (offset < text.size() && std::isspace(static_cast<unsigned char>(text[offset])))
    {
        ++offset;
    }
}

bool Consume(std::string_view text, size_t &offset, char c)
{
    SkipWhitespace(text, offset);
    if (offset >= text.size() || text[offset] != c)
    {
        return false;
    }
    ++offset;
    return true;
}

bool ParseString(std::string_view text, size_t &offset, std::string &out)
{
    SkipWhitespace(text, offset);
    if (offset >= text.size() || text[offset] != '"')
    {
        return false;
    }
    ++offset;
    out.clear();
    while (offset < text.size())
    {
        char c = text[offset++];
        if (c == '"')
        {
            return true;
        }
        if (c == '\\')
        {
            if (offset >= text.size())
            {
                return false;
            }
            char escaped = text[offset++];
            switch (escaped)
            {
                case '"':
                case '\\':
                case '/':
                    out.push_back(escaped);
                    break;
                case 'b':
                    out.push_back('\b');
                    break;
                case 'f':
                    out.push_back('\f');
                    break;
                case 'n':
                    out.push_back('\n');
                    break;
                case 'r':
                    out.push_back('\r');
                    break;
                case 't':
                    out.push_back('\t');
                    break;
                default:
                    return false;
            }
        }
        else
        {
            out.push_back(c);
        }
    }
    return false;
}

bool ParseFlatStringObject(std::string_view text, std::map<std::string, std::string> &out)
{
    size_t offset = 0;
    if (!Consume(text, offset, '{'))
    {
        return false;
    }
    SkipWhitespace(text, offset);
    if (offset < text.size() && text[offset] == '}')
    {
        ++offset;
        SkipWhitespace(text, offset);
        return offset == text.size();
    }

    while (offset < text.size())
    {
        std::string key;
        std::string value;
        if (!ParseString(text, offset, key) || !Consume(text, offset, ':') ||
            !ParseString(text, offset, value))
        {
            return false;
        }
        if (!key.empty())
        {
            // Empty VALUES are kept: an explicit old-name -> "" entry is a drop
            // directive for MigrateNameSet/MigrateNameCounts.
            out[key] = value;
        }

        SkipWhitespace(text, offset);
        if (offset < text.size() && text[offset] == ',')
        {
            ++offset;
            continue;
        }
        if (offset < text.size() && text[offset] == '}')
        {
            ++offset;
            SkipWhitespace(text, offset);
            return offset == text.size();
        }
        return false;
    }
    return false;
}

}  // namespace

std::map<std::string, std::string> ParseLegacyNameMapJSON(const std::string &json)
{
    std::map<std::string, std::string> map;
    if (!ParseFlatStringObject(json, map))
    {
        map.clear();
    }
    return map;
}

MigratedNameSet MigrateNameSet(const std::set<std::string> &names,
                               const std::map<std::string, std::string> &nameMap)
{
    MigratedNameSet result;
    for (const std::string &name : names)
    {
        auto it = nameMap.find(name);
        if (it == nameMap.end())
        {
            // Pass-through: not a legacy key — keep untouched (see header rationale).
            result.names.insert(name);
        }
        else if (it->second.empty())
        {
            ++result.droppedCount;
        }
        else
        {
            result.names.insert(it->second);
            ++result.mappedCount;
        }
    }
    return result;
}

MigratedNameCounts MigrateNameCounts(const std::map<std::string, int> &counts,
                                     const std::map<std::string, std::string> &nameMap)
{
    MigratedNameCounts result;
    for (const auto &entry : counts)
    {
        auto it = nameMap.find(entry.first);
        if (it == nameMap.end())
        {
            auto inserted = result.counts.emplace(entry.first, entry.second);
            if (!inserted.second)
            {
                inserted.first->second = std::max(inserted.first->second, entry.second);
            }
        }
        else if (it->second.empty())
        {
            ++result.droppedCount;
        }
        else
        {
            auto inserted = result.counts.emplace(it->second, entry.second);
            if (!inserted.second)
            {
                // Collision after mapping: keep the max count (pessimistic).
                inserted.first->second = std::max(inserted.first->second, entry.second);
            }
            ++result.mappedCount;
        }
    }
    return result;
}

}  // namespace RoonVis
