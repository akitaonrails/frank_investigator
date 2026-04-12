#ifndef SQLITE_VEC_H
#define SQLITE_VEC_H

#define SQLITE_VEC_VERSION "v0.1.6"
#define SQLITE_VEC_VERSION_MAJOR 0
#define SQLITE_VEC_VERSION_MINOR 1
#define SQLITE_VEC_VERSION_PATCH 6
#define SQLITE_VEC_DATE "vendored"
#define SQLITE_VEC_SOURCE "asg017/sqlite-vec@v0.1.6"

#if defined(_WIN32)
#define SQLITE_VEC_API __declspec(dllexport)
#else
#define SQLITE_VEC_API __attribute__((visibility("default")))
#endif

#endif
