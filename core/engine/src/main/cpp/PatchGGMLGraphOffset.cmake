# Graph-size planning starts at zero without an allocation. Advance its offset
# as an integer, because pointer arithmetic on that null base is undefined.
set(_ow_ggml "${CMAKE_CURRENT_LIST_DIR}/llama.cpp/ggml/src/ggml.c")
file(SHA256 "${_ow_ggml}" _ow_ggml_hash)
set(_ow_ggml_original "7570c26a01a54a016a07d71494ac4b3b594170139ac3251a9a8a703768637456")
set(_ow_ggml_patched "e415a848a03c75e8bfe00ac0ce4a96c3aa40dc8afa7dbc89ecde7d2cc70a2212")
if(_ow_ggml_hash STREQUAL _ow_ggml_original)
    file(READ "${_ow_ggml}" _ow_ggml_source)
    string(REPLACE "*p = (void *) ((char *) ptr + size);"
                   "*p = (void *) ((uintptr_t) ptr + size);"
                   _ow_ggml_source "${_ow_ggml_source}")
    file(WRITE "${_ow_ggml}" "${_ow_ggml_source}")
    file(SHA256 "${_ow_ggml}" _ow_ggml_hash)
endif()
if(NOT _ow_ggml_hash STREQUAL _ow_ggml_patched)
    message(FATAL_ERROR "Unexpected ggml.c source. Review the pinned graph-offset patch before building.")
endif()
