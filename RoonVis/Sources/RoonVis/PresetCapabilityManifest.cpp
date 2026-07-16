#include "PresetCapabilityManifest.h"

#include <cctype>
#include <cstdlib>
#include <string_view>
#include <utility>

namespace RoonVis
{
namespace
{

// --- minimal recursive-descent JSON parser -------------------------------------
//
// The existing hand-rolled parsers (PresetBlocklist, LegacyNameMigration) only
// handle flat string objects/arrays; the capability manifest is nested, so this
// file carries a small generic JSON value model. Same dependency-free spirit:
// no exceptions surface, no allocator tricks, fail-closed on any deviation.

struct JsonValue
{
    enum class Type
    {
        Null,
        Bool,
        Number,
        String,
        Array,
        Object,
    };

    Type type = Type::Null;
    bool boolean = false;
    double number = 0.0;
    std::string string;
    std::vector<JsonValue> array;
    std::vector<std::pair<std::string, JsonValue>> object; // insertion order; first-match lookup
};

constexpr size_t kMaxJsonDepth = 64; // manifest nests 3 deep; cap guards hostile input

class JsonParser
{
public:
    explicit JsonParser(std::string_view text) : _text(text) {}

    bool Parse(JsonValue &out)
    {
        if (!ParseValue(out, 0))
        {
            return false;
        }
        SkipWhitespace();
        return _offset == _text.size(); // trailing garbage is malformed
    }

private:
    void SkipWhitespace()
    {
        while (_offset < _text.size() &&
               std::isspace(static_cast<unsigned char>(_text[_offset])))
        {
            ++_offset;
        }
    }

    bool Peek(char &c)
    {
        SkipWhitespace();
        if (_offset >= _text.size())
        {
            return false;
        }
        c = _text[_offset];
        return true;
    }

    bool Consume(char expected)
    {
        char c = 0;
        if (!Peek(c) || c != expected)
        {
            return false;
        }
        ++_offset;
        return true;
    }

    bool ConsumeLiteral(std::string_view literal)
    {
        if (_text.size() - _offset < literal.size() ||
            _text.substr(_offset, literal.size()) != literal)
        {
            return false;
        }
        _offset += literal.size();
        return true;
    }

    static bool AppendCodepointUTF8(uint32_t codepoint, std::string &out)
    {
        if (codepoint <= 0x7f)
        {
            out.push_back(static_cast<char>(codepoint));
        }
        else if (codepoint <= 0x7ff)
        {
            out.push_back(static_cast<char>(0xc0 | (codepoint >> 6)));
            out.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
        }
        else if (codepoint <= 0xffff)
        {
            out.push_back(static_cast<char>(0xe0 | (codepoint >> 12)));
            out.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3f)));
            out.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
        }
        else if (codepoint <= 0x10ffff)
        {
            out.push_back(static_cast<char>(0xf0 | (codepoint >> 18)));
            out.push_back(static_cast<char>(0x80 | ((codepoint >> 12) & 0x3f)));
            out.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3f)));
            out.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
        }
        else
        {
            return false;
        }
        return true;
    }

    bool ParseHex4(uint32_t &out)
    {
        if (_text.size() - _offset < 4)
        {
            return false;
        }
        out = 0;
        for (int i = 0; i < 4; ++i)
        {
            char c = _text[_offset++];
            out <<= 4;
            if (c >= '0' && c <= '9')
            {
                out |= static_cast<uint32_t>(c - '0');
            }
            else if (c >= 'a' && c <= 'f')
            {
                out |= static_cast<uint32_t>(c - 'a' + 10);
            }
            else if (c >= 'A' && c <= 'F')
            {
                out |= static_cast<uint32_t>(c - 'A' + 10);
            }
            else
            {
                return false;
            }
        }
        return true;
    }

    bool ParseString(std::string &out)
    {
        if (!Consume('"'))
        {
            return false;
        }
        out.clear();
        while (_offset < _text.size())
        {
            char c = _text[_offset++];
            if (c == '"')
            {
                return true;
            }
            if (c == '\\')
            {
                if (_offset >= _text.size())
                {
                    return false;
                }
                char escaped = _text[_offset++];
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
                    case 'u':
                    {
                        uint32_t codepoint = 0;
                        if (!ParseHex4(codepoint))
                        {
                            return false;
                        }
                        if (codepoint >= 0xd800 && codepoint <= 0xdbff)
                        {
                            // High surrogate: a \uXXXX low surrogate must follow.
                            uint32_t low = 0;
                            if (!ConsumeLiteral("\\u") || !ParseHex4(low) ||
                                low < 0xdc00 || low > 0xdfff)
                            {
                                return false;
                            }
                            codepoint = 0x10000 + ((codepoint - 0xd800) << 10) + (low - 0xdc00);
                        }
                        else if (codepoint >= 0xdc00 && codepoint <= 0xdfff)
                        {
                            return false; // lone low surrogate
                        }
                        if (!AppendCodepointUTF8(codepoint, out))
                        {
                            return false;
                        }
                        break;
                    }
                    default:
                        return false;
                }
            }
            else
            {
                out.push_back(c);
            }
        }
        return false; // unterminated
    }

    bool ParseNumber(double &out)
    {
        // strtod accepts a superset (hex, inf, nan, leading '+'); pre-scan the
        // strict JSON grammar first, then convert the accepted span.
        const size_t start = _offset;
        if (_offset < _text.size() && _text[_offset] == '-')
        {
            ++_offset;
        }
        size_t intDigits = 0;
        while (_offset < _text.size() &&
               std::isdigit(static_cast<unsigned char>(_text[_offset])))
        {
            ++_offset;
            ++intDigits;
        }
        if (intDigits == 0)
        {
            return false;
        }
        if (intDigits > 1 && _text[start + (_text[start] == '-' ? 1 : 0)] == '0')
        {
            return false; // leading zero
        }
        if (_offset < _text.size() && _text[_offset] == '.')
        {
            ++_offset;
            size_t fracDigits = 0;
            while (_offset < _text.size() &&
                   std::isdigit(static_cast<unsigned char>(_text[_offset])))
            {
                ++_offset;
                ++fracDigits;
            }
            if (fracDigits == 0)
            {
                return false;
            }
        }
        if (_offset < _text.size() && (_text[_offset] == 'e' || _text[_offset] == 'E'))
        {
            ++_offset;
            if (_offset < _text.size() && (_text[_offset] == '+' || _text[_offset] == '-'))
            {
                ++_offset;
            }
            size_t expDigits = 0;
            while (_offset < _text.size() &&
                   std::isdigit(static_cast<unsigned char>(_text[_offset])))
            {
                ++_offset;
                ++expDigits;
            }
            if (expDigits == 0)
            {
                return false;
            }
        }
        const std::string span(_text.substr(start, _offset - start));
        out = std::strtod(span.c_str(), nullptr);
        return true;
    }

    bool ParseValue(JsonValue &out, size_t depth)
    {
        if (depth > kMaxJsonDepth)
        {
            return false;
        }
        char c = 0;
        if (!Peek(c))
        {
            return false;
        }
        switch (c)
        {
            case '{':
                return ParseObject(out, depth);
            case '[':
                return ParseArray(out, depth);
            case '"':
                out.type = JsonValue::Type::String;
                return ParseString(out.string);
            case 't':
                out.type = JsonValue::Type::Bool;
                out.boolean = true;
                return ConsumeLiteral("true");
            case 'f':
                out.type = JsonValue::Type::Bool;
                out.boolean = false;
                return ConsumeLiteral("false");
            case 'n':
                out.type = JsonValue::Type::Null;
                return ConsumeLiteral("null");
            default:
                out.type = JsonValue::Type::Number;
                return ParseNumber(out.number);
        }
    }

    bool ParseObject(JsonValue &out, size_t depth)
    {
        out.type = JsonValue::Type::Object;
        if (!Consume('{'))
        {
            return false;
        }
        char c = 0;
        if (Peek(c) && c == '}')
        {
            ++_offset;
            return true;
        }
        while (true)
        {
            std::string key;
            SkipWhitespace();
            if (!ParseString(key) || !Consume(':'))
            {
                return false;
            }
            JsonValue value;
            if (!ParseValue(value, depth + 1))
            {
                return false;
            }
            out.object.emplace_back(std::move(key), std::move(value));
            if (Consume(','))
            {
                continue;
            }
            return Consume('}');
        }
    }

    bool ParseArray(JsonValue &out, size_t depth)
    {
        out.type = JsonValue::Type::Array;
        if (!Consume('['))
        {
            return false;
        }
        char c = 0;
        if (Peek(c) && c == ']')
        {
            ++_offset;
            return true;
        }
        while (true)
        {
            JsonValue value;
            if (!ParseValue(value, depth + 1))
            {
                return false;
            }
            out.array.push_back(std::move(value));
            if (Consume(','))
            {
                continue;
            }
            return Consume(']');
        }
    }

    std::string_view _text;
    size_t _offset = 0;
};

// --- schema decode helpers ------------------------------------------------------

const JsonValue *FindMember(const JsonValue &object, std::string_view key)
{
    if (object.type != JsonValue::Type::Object)
    {
        return nullptr;
    }
    for (const auto &member : object.object)
    {
        if (member.first == key)
        {
            return &member.second;
        }
    }
    return nullptr;
}

// Required string member: present AND a string, else malformed.
bool GetString(const JsonValue &object, std::string_view key, std::string &out)
{
    const JsonValue *value = FindMember(object, key);
    if (value == nullptr || value->type != JsonValue::Type::String)
    {
        return false;
    }
    out = value->string;
    return true;
}

// Optional string member: absent -> default kept; present-but-not-a-string -> malformed.
bool GetOptionalString(const JsonValue &object, std::string_view key, std::string &out)
{
    const JsonValue *value = FindMember(object, key);
    if (value == nullptr)
    {
        return true;
    }
    if (value->type != JsonValue::Type::String)
    {
        return false;
    }
    out = value->string;
    return true;
}

bool GetNumber(const JsonValue &object, std::string_view key, double &out)
{
    const JsonValue *value = FindMember(object, key);
    if (value == nullptr || value->type != JsonValue::Type::Number)
    {
        return false;
    }
    out = value->number;
    return true;
}

bool GetOptionalNumber(const JsonValue &object, std::string_view key, double &out)
{
    const JsonValue *value = FindMember(object, key);
    if (value == nullptr)
    {
        return true;
    }
    if (value->type != JsonValue::Type::Number)
    {
        return false;
    }
    out = value->number;
    return true;
}

bool GetInt(const JsonValue &object, std::string_view key, int &out)
{
    double number = 0.0;
    if (!GetNumber(object, key, number))
    {
        return false;
    }
    out = static_cast<int>(number);
    return static_cast<double>(out) == number; // integral, in range
}

bool GetOptionalInt(const JsonValue &object, std::string_view key, int &out)
{
    if (FindMember(object, key) == nullptr)
    {
        return true;
    }
    return GetInt(object, key, out);
}

// Enum decodes: unknown strings are MALFORMED (fail closed), never defaulted.

bool DecodeSafety(const std::string &text, PresetSafety &out)
{
    if (text == "safe")
    {
        out = PresetSafety::Safe;
    }
    else if (text == "known-crash")
    {
        out = PresetSafety::KnownCrash;
    }
    else if (text == "unsupported")
    {
        out = PresetSafety::Unsupported;
    }
    else
    {
        return false;
    }
    return true;
}

bool DecodeSteadyState(const std::string &text, SteadyStateVerdict &out)
{
    if (text == "unknown")
    {
        out = SteadyStateVerdict::Unknown;
    }
    else if (text == "pass")
    {
        out = SteadyStateVerdict::Pass;
    }
    else if (text == "marginal")
    {
        out = SteadyStateVerdict::Marginal;
    }
    else if (text == "fail")
    {
        out = SteadyStateVerdict::Fail;
    }
    else
    {
        return false;
    }
    return true;
}

bool DecodeMechanism(const std::string &text, ActivationMechanism &out)
{
    if (text == "none")
    {
        out = ActivationMechanism::None;
    }
    else if (text == "tier1-cache")
    {
        out = ActivationMechanism::Tier1Cache;
    }
    else if (text == "program-blob")
    {
        out = ActivationMechanism::ProgramBlob;
    }
    else
    {
        return false;
    }
    return true;
}

bool DecodeActivationVerdict(const std::string &text, ActivationVerdict &out)
{
    if (text == "unknown")
    {
        out = ActivationVerdict::Unknown;
    }
    else if (text == "sufficient")
    {
        out = ActivationVerdict::Sufficient;
    }
    else if (text == "insufficient")
    {
        out = ActivationVerdict::Insufficient;
    }
    else if (text == "unresolved")
    {
        out = ActivationVerdict::Unresolved;
    }
    else
    {
        return false;
    }
    return true;
}

bool DecodeProfile(const JsonValue &json, CapabilityProfile &out)
{
    // deviceTier + fps are required (they gate every mismatch decision); the
    // build-identity strings and rvppVersion are optional-with-default so an
    // older manifest stays decodable (the mismatch rules handle staleness).
    if (!GetString(json, "deviceTier", out.deviceTier) || !GetInt(json, "fps", out.fps))
    {
        return false;
    }
    if (!GetOptionalString(json, "drawable", out.drawable) ||
        !GetOptionalString(json, "projectMRevision", out.projectMRevision) ||
        !GetOptionalString(json, "angleRevision", out.angleRevision) ||
        !GetOptionalInt(json, "rvppVersion", out.rvppVersion) ||
        !GetOptionalString(json, "transpileSalts", out.transpileSalts) ||
        !GetOptionalString(json, "tier1CacheFingerprint", out.tier1CacheFingerprint))
    {
        return false;
    }
    return true;
}

bool DecodeEvidence(const JsonValue &json, CapabilityEvidence &out)
{
    if (json.type != JsonValue::Type::Object)
    {
        return false;
    }
    double sampleCount = 0.0;
    if (!GetOptionalNumber(json, "settledP50Ms", out.settledP50Ms) ||
        !GetOptionalNumber(json, "settledP95Ms", out.settledP95Ms) ||
        !GetOptionalNumber(json, "settledP99Ms", out.settledP99Ms) ||
        !GetOptionalNumber(json, "overBudgetRate", out.overBudgetRate) ||
        !GetOptionalNumber(json, "sampleCount", sampleCount))
    {
        return false;
    }
    out.sampleCount = static_cast<int64_t>(sampleCount);
    return true;
}

bool DecodeRecord(const JsonValue &json, CapabilityRecord &out)
{
    if (json.type != JsonValue::Type::Object)
    {
        return false;
    }
    // name + the four verdict enums are required; a record without them is
    // meaningless and defaulting a mechanism/verdict could over-admit.
    std::string safety;
    std::string steadyState;
    std::string mechanism;
    std::string verdict;
    if (!GetString(json, "name", out.name) || out.name.empty() ||
        !GetString(json, "safety", safety) ||
        !GetString(json, "steadyState", steadyState) ||
        !GetString(json, "activationMechanism", mechanism) ||
        !GetString(json, "activationVerdict", verdict))
    {
        return false;
    }
    if (!DecodeSafety(safety, out.safety) ||
        !DecodeSteadyState(steadyState, out.steadyState) ||
        !DecodeMechanism(mechanism, out.activationMechanism) ||
        !DecodeActivationVerdict(verdict, out.activationVerdict))
    {
        return false;
    }
    if (!GetOptionalString(json, "path", out.path))
    {
        return false;
    }
    const JsonValue *evidence = FindMember(json, "evidence");
    if (evidence != nullptr && !DecodeEvidence(*evidence, out.evidence))
    {
        return false;
    }
    return true;
}

bool ProfileMatches(const CapabilityProfile &parsed, const CapabilityProfile &expected)
{
    // deviceTier + fps ALWAYS gate; everything else only when the caller pinned
    // a non-empty / non-zero expectation (see the header contract).
    if (parsed.deviceTier != expected.deviceTier || parsed.fps != expected.fps)
    {
        return false;
    }
    if (!expected.drawable.empty() && parsed.drawable != expected.drawable)
    {
        return false;
    }
    if (!expected.projectMRevision.empty() && parsed.projectMRevision != expected.projectMRevision)
    {
        return false;
    }
    if (!expected.angleRevision.empty() && parsed.angleRevision != expected.angleRevision)
    {
        return false;
    }
    if (expected.rvppVersion != 0 && parsed.rvppVersion != expected.rvppVersion)
    {
        return false;
    }
    if (!expected.transpileSalts.empty() && parsed.transpileSalts != expected.transpileSalts)
    {
        return false;
    }
    if (!expected.tier1CacheFingerprint.empty() &&
        parsed.tier1CacheFingerprint != expected.tier1CacheFingerprint)
    {
        return false;
    }
    return true;
}

} // namespace

ManifestLoadStatus ParseCapabilityManifest(const std::string &jsonText,
                                           const CapabilityProfile &expected,
                                           CapabilityManifest &out)
{
    out = CapabilityManifest();

    JsonValue root;
    JsonParser parser(jsonText);
    if (!parser.Parse(root) || root.type != JsonValue::Type::Object)
    {
        return ManifestLoadStatus::Malformed;
    }

    CapabilityManifest manifest;
    if (!GetInt(root, "schema", manifest.schema) || manifest.schema != 1)
    {
        // Unknown schema versions fail closed: the caller regenerates.
        return ManifestLoadStatus::Malformed;
    }

    const JsonValue *profile = FindMember(root, "profile");
    if (profile == nullptr || profile->type != JsonValue::Type::Object ||
        !DecodeProfile(*profile, manifest.profile))
    {
        return ManifestLoadStatus::Malformed;
    }

    const JsonValue *presets = FindMember(root, "presets");
    if (presets == nullptr || presets->type != JsonValue::Type::Array)
    {
        return ManifestLoadStatus::Malformed;
    }
    manifest.presets.reserve(presets->array.size());
    for (const JsonValue &entry : presets->array)
    {
        CapabilityRecord record;
        if (!DecodeRecord(entry, record))
        {
            return ManifestLoadStatus::Malformed;
        }
        manifest.presets.push_back(std::move(record));
    }

    // Malformed always wins over mismatch (untrustworthy content); a mismatch
    // still hands the parsed manifest back for logging.
    out = std::move(manifest);
    if (!ProfileMatches(out.profile, expected))
    {
        return ManifestLoadStatus::ProfileMismatch;
    }
    return ManifestLoadStatus::Valid;
}

} // namespace RoonVis
