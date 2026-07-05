#pragma once

#include <cstddef>
#include <algorithm>
#include <cctype>
#include <map>
#include <set>
#include <string>
#include <utility>
#include <vector>

namespace RoonVis
{

struct PresetShelfInput
{
    size_t index = 0;
    std::string filename;
    std::string title;
    bool favorite = false;
};

struct PresetShelf
{
    std::string title;
    std::vector<size_t> indexes;
};

inline std::string TrimPresetShelfString(const std::string &value)
{
    size_t begin = 0;
    while (begin < value.size() && std::isspace(static_cast<unsigned char>(value[begin])))
    {
        ++begin;
    }

    size_t end = value.size();
    while (end > begin && std::isspace(static_cast<unsigned char>(value[end - 1])))
    {
        --end;
    }

    return value.substr(begin, end - begin);
}

inline std::string PresetShelfBasenameWithoutExtension(const std::string &filename)
{
    size_t slash = filename.find_last_of("/\\");
    size_t begin = slash == std::string::npos ? 0 : slash + 1;
    std::string basename = filename.substr(begin);
    size_t dot = basename.find_last_of('.');
    if (dot == std::string::npos || dot == 0)
    {
        return basename;
    }
    return basename.substr(0, dot);
}

inline std::string PresetShelfLeadingToken(const std::string &filename)
{
    std::string basename = PresetShelfBasenameWithoutExtension(filename);
    size_t delimiter = basename.find("_-_");
    if (delimiter == std::string::npos)
    {
        size_t hyphen = basename.find('-');
        size_t underscore = basename.find('_');
        if (hyphen == std::string::npos)
        {
            delimiter = underscore;
        }
        else if (underscore == std::string::npos)
        {
            delimiter = hyphen;
        }
        else
        {
            delimiter = std::min(hyphen, underscore);
        }
    }
    return TrimPresetShelfString(basename.substr(0, delimiter));
}

inline std::string PresetShelfNormalizedKey(const std::string &value)
{
    std::string key;
    key.reserve(value.size());
    bool previousSpace = false;
    for (char character : value)
    {
        unsigned char byte = static_cast<unsigned char>(character);
        if (std::isspace(byte))
        {
            if (!previousSpace && !key.empty())
            {
                key.push_back(' ');
                previousSpace = true;
            }
            continue;
        }
        key.push_back(static_cast<char>(std::tolower(byte)));
        previousSpace = false;
    }
    if (!key.empty() && key.back() == ' ')
    {
        key.pop_back();
    }
    return key;
}

inline std::string PresetAuthorClusterTitle(const std::string &filename)
{
    std::string token = PresetShelfLeadingToken(filename);
    return token.empty() ? "Other" : token;
}

inline bool ComparePresetShelfInputByTitle(const PresetShelfInput *left, const PresetShelfInput *right)
{
    std::string leftKey = PresetShelfNormalizedKey(left->title.empty() ? left->filename : left->title);
    std::string rightKey = PresetShelfNormalizedKey(right->title.empty() ? right->filename : right->title);
    if (leftKey != rightKey)
    {
        return leftKey < rightKey;
    }
    return left->index < right->index;
}

inline std::vector<PresetShelf> BuildPresetShelves(const std::vector<PresetShelfInput> &presets,
                                                   bool favoritesOnly,
                                                   size_t minimumClusterSize = 3)
{
    std::vector<PresetShelf> shelves;
    std::vector<const PresetShelfInput *> visible;
    visible.reserve(presets.size());
    for (const PresetShelfInput &preset : presets)
    {
        if (!favoritesOnly || preset.favorite)
        {
            visible.push_back(&preset);
        }
    }
    std::stable_sort(visible.begin(), visible.end(), ComparePresetShelfInputByTitle);

    // Favourites tab: a single "Favorites" shelf. The Presets tab does NOT get a Favorites
    // shelf — favourites appear in their artist clusters there like any other preset, and
    // the current preset is surfaced by a "Now Playing" section added in the display layer.
    if (favoritesOnly)
    {
        if (visible.empty())
        {
            return shelves;
        }
        PresetShelf shelf;
        shelf.title = "Favorites";
        for (const PresetShelfInput *preset : visible)
        {
            shelf.indexes.push_back(preset->index);
        }
        shelves.push_back(std::move(shelf));
        return shelves;
    }

    struct Cluster
    {
        std::string title;
        std::vector<const PresetShelfInput *> presets;
    };
    std::map<std::string, Cluster> clusters;
    for (const PresetShelfInput *preset : visible)
    {
        std::string title = PresetAuthorClusterTitle(preset->filename);
        std::string key = PresetShelfNormalizedKey(title);
        if (key.empty())
        {
            key = "other";
            title = "Other";
        }
        Cluster &cluster = clusters[key];
        if (cluster.title.empty())
        {
            cluster.title = title;
        }
        cluster.presets.push_back(preset);
    }

    PresetShelf other;
    other.title = "Other";
    for (const auto &entry : clusters)
    {
        const Cluster &cluster = entry.second;
        if (cluster.presets.size() < minimumClusterSize || PresetShelfNormalizedKey(cluster.title) == "other")
        {
            for (const PresetShelfInput *preset : cluster.presets)
            {
                other.indexes.push_back(preset->index);
            }
            continue;
        }

        PresetShelf shelf;
        shelf.title = cluster.title;
        for (const PresetShelfInput *preset : cluster.presets)
        {
            shelf.indexes.push_back(preset->index);
        }
        shelves.push_back(std::move(shelf));
    }

    if (!other.indexes.empty())
    {
        shelves.push_back(std::move(other));
    }
    return shelves;
}

inline std::vector<size_t> FlattenPresetShelfIndexes(const std::vector<PresetShelf> &shelves)
{
    std::vector<size_t> indexes;
    std::set<size_t> seen;
    for (const PresetShelf &shelf : shelves)
    {
        for (size_t index : shelf.indexes)
        {
            if (seen.insert(index).second)
            {
                indexes.push_back(index);
            }
        }
    }
    return indexes;
}

}  // namespace RoonVis
