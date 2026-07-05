#pragma once

#include <cstdio>

struct TestStats
{
    int passed = 0;
    int failed = 0;
};

inline TestStats &Stats()
{
    static TestStats stats;
    return stats;
}

#define CHECK(expr)                                                                                 \
    do                                                                                              \
    {                                                                                               \
        if (expr)                                                                                   \
        {                                                                                           \
            ++Stats().passed;                                                                       \
        }                                                                                           \
        else                                                                                        \
        {                                                                                           \
            ++Stats().failed;                                                                       \
            std::fprintf(stderr, "CHECK failed: %s:%d: %s\n", __FILE__, __LINE__, #expr);           \
        }                                                                                           \
    } while (0)

#define REQUIRE(expr)                                                                               \
    do                                                                                              \
    {                                                                                               \
        if (expr)                                                                                   \
        {                                                                                           \
            ++Stats().passed;                                                                       \
        }                                                                                           \
        else                                                                                        \
        {                                                                                           \
            ++Stats().failed;                                                                       \
            std::fprintf(stderr, "REQUIRE failed: %s:%d: %s\n", __FILE__, __LINE__, #expr);         \
            return;                                                                                 \
        }                                                                                           \
    } while (0)
