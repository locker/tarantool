/*
 * Copyright 2010-2016, Tarantool AUTHORS, please see AUTHORS file.
 *
 * Redistribution and use in source and binary forms, with or
 * without modification, are permitted provided that the following
 * conditions are met:
 *
 * 1. Redistributions of source code must retain the above
 *    copyright notice, this list of conditions and the
 *    following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above
 *    copyright notice, this list of conditions and the following
 *    disclaimer in the documentation and/or other materials
 *    provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY <COPYRIGHT HOLDER> ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
 * <COPYRIGHT HOLDER> OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
 * BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
 * THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */
#include "tuple_dictionary.h"

#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "assoc.h"
#include "error.h"
#include "diag.h"
#include "salad/grp_alloc.h"
#include "trivia/util.h"

#include "PMurHash.h"

field_name_hash_f field_name_hash;

/** Free tuple dictionary and its content. */
static inline void
tuple_dictionary_delete(struct tuple_dictionary *dict)
{
	assert(dict->refs == 0);
	if (dict->hash != NULL) {
		mh_strnu32_delete(dict->hash);
		free(dict->names);
	} else {
		assert(dict->names == NULL);
	}
	free(dict);
}

/**
 * Set a new name in a dictionary. Check duplicates. Memory must
 * be reserved already.
 * @param dict Tuple dictionary.
 * @param name New name.
 * @param name_len Length of @a name.
 * @param fieldno Field number.
 *
 * @retval  0 Success.
 * @retval -1 Duplicate name error.
 */
static inline int
tuple_dictionary_set_name(struct tuple_dictionary *dict, const char *name,
			  uint32_t name_len, uint32_t fieldno)
{
	assert(fieldno < dict->name_count);
	uint32_t name_hash = field_name_hash(name, name_len);
	struct mh_strnu32_key_t key = {
		name, name_len, name_hash
	};
	mh_int_t rc = mh_strnu32_find(dict->hash, &key, NULL);
	if (rc != mh_end(dict->hash)) {
		diag_set(ClientError, ER_SPACE_FIELD_IS_DUPLICATE,
			 name);
		return -1;
	}
	struct mh_strnu32_node_t name_node = {
		name, name_len, name_hash, fieldno
	};
	mh_strnu32_put(dict->hash, &name_node, NULL, NULL);
	return 0;
}

/**
 * Helper function that constructs a tuple dictionary from an array of field
 * names. A pointer to a field name is supposed to be stored at offset
 * name_data_offset in object of size name_data_objsize. This way we can use
 * not only a plain string array as a source of field names, but also an array
 * of container objects (e.g. field_def).
 */
static struct tuple_dictionary *
tuple_dictionary_new_impl(const void *name_data, size_t name_data_offset,
			  size_t name_data_objsize, uint32_t name_count)
{
	/*
	 * Sic: We don't allocate dict and names from a continuous memory
	 * block, because we need to swap names, see tuple_dictionary_swap().
	 */
	struct tuple_dictionary *dict = xmalloc(sizeof(*dict));
	dict->refs = 1;
	dict->name_count = name_count;
	if (name_count == 0) {
		dict->names = NULL;
		dict->hash = NULL;
		return dict;
	}
	struct grp_alloc all = grp_alloc_initializer();
	grp_alloc_reserve_data(&all, sizeof(dict->names[0]) * name_count);
	for (uint32_t i = 0; i < name_count; ++i) {
		const char *const *name = name_data + i * name_data_objsize +
					  name_data_offset;
		grp_alloc_reserve_str0(&all, *name);
	}
	grp_alloc_use(&all, xmalloc(grp_alloc_size(&all)));
	dict->names = grp_alloc_create_data(
		&all, sizeof(dict->names[0]) * name_count);
	dict->hash = mh_strnu32_new();
	mh_strnu32_reserve(dict->hash, name_count, NULL);
	for (uint32_t i = 0; i < name_count; ++i) {
		const char *const *name = name_data + i * name_data_objsize +
					  name_data_offset;
		size_t len = strlen(*name);
		dict->names[i] = grp_alloc_create_str(&all, *name, len);
		if (tuple_dictionary_set_name(dict, dict->names[i],
					      len, i) != 0) {
			mh_strnu32_delete(dict->hash);
			free(dict->names);
			free(dict);
			return NULL;
		}
	}
	assert(grp_alloc_size(&all) == 0);
	return dict;
}

struct tuple_dictionary *
tuple_dictionary_new(const struct field_def *fields, uint32_t field_count)
{
	return tuple_dictionary_new_impl(
			fields, offsetof(struct field_def, name),
			sizeof(struct field_def), field_count);
}

struct tuple_dictionary *
tuple_dictionary_dup(const struct tuple_dictionary *dict)
{
	return tuple_dictionary_new_impl(dict->names, 0, sizeof(char *),
					 dict->name_count);
}

uint32_t
tuple_dictionary_hash_process(const struct tuple_dictionary *dict,
			      uint32_t *ph, uint32_t *pcarry)
{
	uint32_t size = 0;
	for (uint32_t i = 0; i < dict->name_count; ++i) {
		uint32_t name_len = strlen(dict->names[i]);
		PMurHash32_Process(ph, pcarry, dict->names[i], name_len);
		size += name_len;
	}
	return size;
}

int
tuple_dictionary_cmp(const struct tuple_dictionary *a,
		     const struct tuple_dictionary *b)
{
	if (a->name_count != b->name_count)
		return a->name_count > b->name_count ? 1 : -1;
	for (uint32_t i = 0; i < a->name_count; ++i) {
		int ret = strcmp(a->names[i], b->names[i]);
		if (ret != 0)
			return ret;
	}
	return 0;
}

void
tuple_dictionary_swap(struct tuple_dictionary *a, struct tuple_dictionary *b)
{
	int a_refs = a->refs;
	int b_refs = b->refs;
	struct tuple_dictionary t = *a;
	*a = *b;
	*b = t;
	a->refs = a_refs;
	b->refs = b_refs;
}

void
tuple_dictionary_unref(struct tuple_dictionary *dict)
{
	assert(dict->refs > 0);
	if (--dict->refs == 0)
		tuple_dictionary_delete(dict);
}

void
tuple_dictionary_ref(struct tuple_dictionary *dict)
{
	++dict->refs;
}

int
tuple_fieldno_by_name(struct tuple_dictionary *dict, const char *name,
		      uint32_t name_len, uint32_t name_hash, uint32_t *fieldno)
{
	struct mh_strnu32_t *hash = dict->hash;
	if (hash == NULL)
		return -1;
	struct mh_strnu32_key_t key = {name, name_len, name_hash};
	mh_int_t rc = mh_strnu32_find(hash, &key, NULL);
	if (rc == mh_end(hash))
		return -1;
	*fieldno = mh_strnu32_node(hash, rc)->val;
	return 0;
}
