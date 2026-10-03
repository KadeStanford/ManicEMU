// SPDX-License-Identifier: AGPL-3.0-or-later
// ABI of the pinned RetroArch savefile_ptr_get export in the original IPA.
// Verified against Daiuno/RetroArch 00689c83, save.c and lists/string_list.h.
// Access only while the frontend is executing this core's retro_run.
union MTSaveAttr { bool b; int i; void *p; };
struct MTSaveEntry { char *data; void *userdata; union MTSaveAttr attr; };
struct MTSaveList { struct MTSaveEntry *elems; size_t size,cap; };
