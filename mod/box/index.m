/*
 * Copyright (C) 2010 Mail.RU
 * Copyright (C) 2010 Yuriy Vostrikov
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY AUTHOR AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL AUTHOR OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */
#include "index.h"
#include "tree.h"
#include "say.h"
#include "tuple.h"
#include "pickle.h"
#include "exception.h"
#include "box.h"
#include "salloc.h"
#include "assoc.h"

const char *field_data_type_strs[] = {"NUM", "NUM64", "STR", "\0"};
const char *index_type_strs[] = { "HASH", "TREE", "\0" };

static struct box_tuple *
iterator_next_equal(struct iterator *it __attribute__((unused)))
{
	return NULL;
}

struct box_tuple *
iterator_first_equal(struct iterator *it)
{
	it->next_equal = iterator_next_equal;
	return it->next(it);
}

/* {{{ Index -- base class for all indexes. ********************/

@implementation Index

@class Hash32Index;
@class Hash64Index;
@class HashStrIndex;
@class TreeIndex;

+ (Index *) alloc: (enum index_type) type :(struct key_def *) key_def
	:(struct space *) space;
{
	switch (type) {
	case HASH:
		/* Hash index, check key type.
		 * Hash indes always has a single-field key.
		 */
		switch (key_def->parts[0].type) {
		case NUM:
			return [Hash32Index alloc]; /* 32-bit integer hash */
		case NUM64:
			return [Hash64Index alloc]; /* 64-bit integer hash */
		case STRING:
			return [HashStrIndex alloc]; /* string hash */
		default:
			break;
		}
		break;
	case TREE:
		return [TreeIndex alloc: key_def :space];
	default:
		break;
	}
	panic("unsupported index type");
}

- (id) init: (enum index_type) type_arg :(struct key_def *) key_def_arg
	:(struct space *) space_arg :(u32) n_arg;
{
	self = [super init];
	key_def = *key_def_arg;
	type = type_arg;
	n = n_arg;
	space = space_arg;
	position = [self allocIterator];
	[self enable];
	return self;
}

- (void) free
{
	sfree(key_def.parts);
	sfree(key_def.cmp_order);
	position->free(position);
	[super free];
}

- (void) enable
{
	[self subclassResponsibility: _cmd];
}

- (size_t) size
{
	[self subclassResponsibility: _cmd];
	return 0;
}

- (struct box_tuple *) min
{
	[self subclassResponsibility: _cmd];
	return NULL;
}

- (struct box_tuple *) max
{
	[self subclassResponsibility: _cmd];
	return NULL;
}

- (struct box_tuple *) find: (void *) key
{
	(void) key;
	[self subclassResponsibility: _cmd];
	return NULL;
}

- (struct box_tuple *) findByTuple: (struct box_tuple *) pattern
{
	(void) pattern;
	[self subclassResponsibility: _cmd];
	return NULL;
}

- (void) remove: (struct box_tuple *) tuple
{
	(void) tuple;
	[self subclassResponsibility: _cmd];
}

- (void) replace: (struct box_tuple *) old_tuple
	:(struct box_tuple *) new_tuple
{
	(void) old_tuple;
	(void) new_tuple;
	[self subclassResponsibility: _cmd];
}

- (struct iterator *) allocIterator
{
	[self subclassResponsibility: _cmd];
	return NULL;
}

- (void) initIterator: (struct iterator *) iterator
{
	(void) iterator;
	[self subclassResponsibility: _cmd];
}

- (void) initIterator: (struct iterator *) iterator :(void *) key
			:(int) part_count
{
	(void) iterator;
	(void) part_count;
	(void) key;
	[self subclassResponsibility: _cmd];
}
@end

/* }}} */

/* {{{ HashIndex -- base class for all hashes. ********************/

@interface HashIndex: Index
@end

struct hash_iterator {
	struct iterator base; /* Must be the first member. */
	struct mh_i32ptr_t *hash;
	mh_int_t h_pos;
};

static inline struct hash_iterator *
hash_iterator(struct iterator *it)
{
	return (struct hash_iterator *) it;
}

struct box_tuple *
hash_iterator_next(struct iterator *iterator)
{
	assert(iterator->next = hash_iterator_next);

	struct hash_iterator *it = hash_iterator(iterator);

	while (it->h_pos != mh_end(it->hash)) {
		if (mh_exist(it->hash, it->h_pos))
			return mh_value(it->hash, it->h_pos++);
		it->h_pos++;
	}
	return NULL;
}

void
hash_iterator_free(struct iterator *iterator)
{
	assert(iterator->next = hash_iterator_next);
	sfree(iterator);
}


@implementation HashIndex
- (void) free
{
	[super free];
}

- (struct box_tuple *) min
{
	tnt_raise(ClientError, :ER_UNSUPPORTED);
	return NULL;
}

- (struct box_tuple *) max
{
	tnt_raise(ClientError, :ER_UNSUPPORTED);
	return NULL;
}

- (struct box_tuple *) findByTuple: (struct box_tuple *) tuple
{
	/* Hash index currently is always single-part. */
	void *field = tuple_field(tuple, key_def.parts[0].fieldno);
	if (field == NULL)
		tnt_raise(ClientError, :ER_NO_SUCH_FIELD, key_def.parts[0].fieldno);
	return [self find: field];
}

- (struct iterator *) allocIterator
{
	struct hash_iterator *it = salloc(sizeof(struct hash_iterator));
	if (it) {
		memset(it, 0, sizeof(struct hash_iterator));
		it->base.next = hash_iterator_next;
		it->base.free = hash_iterator_free;
	}
	return (struct iterator *) it;
}
@end

/* }}} */

/* {{{ Hash32Index ************************************************/

@interface Hash32Index: HashIndex {
	 struct mh_i32ptr_t *int_hash;
};
@end

@implementation Hash32Index
- (void) free
{
	mh_i32ptr_destroy(int_hash);
	[super free];
}

- (void) enable
{
	enabled = true;
	int_hash = mh_i32ptr_init();
}

- (size_t) size
{
	return mh_size(int_hash);
}

- (struct box_tuple *) find: (void *) field
{
	struct box_tuple *ret = NULL;
	u32 field_size = load_varint32(&field);
	u32 num = *(u32 *)field;

	if (field_size != 4)
		tnt_raise(IllegalParams, :"key is not u32");

	mh_int_t k = mh_i32ptr_get(int_hash, num);
	if (k != mh_end(int_hash))
		ret = mh_value(int_hash, k);
#ifdef DEBUG
	say_debug("Hash32Index find(self:%p, key:%i) = %p", self, num, ret);
#endif
	return ret;
}

- (void) remove: (struct box_tuple *) tuple
{
	void *field = tuple_field(tuple, key_def.parts[0].fieldno);
	unsigned int field_size = load_varint32(&field);
	u32 num = *(u32 *)field;

	if (field_size != 4)
		tnt_raise(IllegalParams, :"key is not u32");

	mh_int_t k = mh_i32ptr_get(int_hash, num);
	if (k != mh_end(int_hash))
		mh_i32ptr_del(int_hash, k);
#ifdef DEBUG
	say_debug("Hash32Index remove(self:%p, key:%i)", self, num);
#endif
}

- (void) replace: (struct box_tuple *) old_tuple
	:(struct box_tuple *) new_tuple
{
	void *field = tuple_field(new_tuple, key_def.parts[0].fieldno);
	u32 field_size = load_varint32(&field);
	u32 num = *(u32 *)field;

	if (field_size != 4)
		tnt_raise(IllegalParams, :"key is not u32");

	if (old_tuple != NULL) {
		void *old_field = tuple_field(old_tuple, key_def.parts[0].fieldno);
		load_varint32(&old_field);
		u32 old_num = *(u32 *)old_field;
		mh_int_t k = mh_i32ptr_get(int_hash, old_num);
		if (k != mh_end(int_hash))
			mh_i32ptr_del(int_hash, k);
	}

	mh_i32ptr_put(int_hash, num, new_tuple, NULL);

#ifdef DEBUG
	say_debug("Hash32Index replace(self:%p, old_tuple:%p, new_tuple:%p) key:%i",
		  self, old_tuple, new_tuple, num);
#endif
}

- (void) initIterator: (struct iterator *) iterator
{
	struct hash_iterator *it = hash_iterator(iterator);

	assert(iterator->next = hash_iterator_next);

	it->base.next_equal = 0; /* Should not be used. */
	it->h_pos = mh_begin(int_hash);
	it->hash = int_hash;
}

- (void) initIterator: (struct iterator *) iterator :(void *) key
			:(int) part_count
{
	struct hash_iterator *it = hash_iterator(iterator);

	(void) part_count;
	assert(part_count == 1);
	assert(iterator->next = hash_iterator_next);

	u32 field_size = load_varint32(&key);
	u32 num = *(u32 *)key;

	if (field_size != 4)
		tnt_raise(IllegalParams, :"key is not u32");

	it->base.next_equal = iterator_first_equal;
	it->h_pos = mh_i32ptr_get(int_hash, num);
	it->hash = int_hash;
}
@end

/* }}} */

/* {{{ Hash64Index ************************************************/

@interface Hash64Index: HashIndex {
	struct mh_i64ptr_t *int64_hash;
};
@end

@implementation Hash64Index
- (void) free
{
	mh_i64ptr_destroy(int64_hash);
	[super free];
}

- (void) enable
{
	enabled = true;
	int64_hash = mh_i64ptr_init();
}

- (size_t) size
{
	return mh_size(int64_hash);
}

- (struct box_tuple *) find: (void *) field
{
	struct box_tuple *ret = NULL;
	u32 field_size = load_varint32(&field);
	u64 num = *(u64 *)field;

	if (field_size != 8)
		tnt_raise(IllegalParams, :"key is not u64");

	mh_int_t k = mh_i64ptr_get(int64_hash, num);
	if (k != mh_end(int64_hash))
		ret = mh_value(int64_hash, k);
#ifdef DEBUG
	say_debug("Hash64Index find(self:%p, key:%"PRIu64") = %p", self, num, ret);
#endif
	return ret;
}

- (void) remove: (struct box_tuple *) tuple
{
	void *field = tuple_field(tuple, key_def.parts[0].fieldno);
	unsigned int field_size = load_varint32(&field);
	u64 num = *(u64 *)field;

	if (field_size != 8)
		tnt_raise(IllegalParams, :"key is not u64");

	mh_int_t k = mh_i64ptr_get(int64_hash, num);
	if (k != mh_end(int64_hash))
		mh_i64ptr_del(int64_hash, k);
#ifdef DEBUG
	say_debug("Hash64Index remove(self:%p, key:%"PRIu64")", self, num);
#endif
}

- (void) replace: (struct box_tuple *) old_tuple
	:(struct box_tuple *) new_tuple
{
	void *field = tuple_field(new_tuple, key_def.parts[0].fieldno);
	u32 field_size = load_varint32(&field);
	u64 num = *(u64 *)field;

	if (field_size != 8)
		tnt_raise(IllegalParams, :"key is not u64");

	if (old_tuple != NULL) {
		void *old_field = tuple_field(old_tuple,
					      key_def.parts[0].fieldno);
		load_varint32(&old_field);
		u64 old_num = *(u64 *)old_field;
		mh_int_t k = mh_i64ptr_get(int64_hash, old_num);
		if (k != mh_end(int64_hash))
			mh_i64ptr_del(int64_hash, k);
	}

	mh_i64ptr_put(int64_hash, num, new_tuple, NULL);
#ifdef DEBUG
	say_debug("Hash64Index replace(self:%p, old_tuple:%p, tuple:%p) key:%"PRIu64,
		  self, old_tuple, new_tuple, num);
#endif
}

- (void) initIterator: (struct iterator *) iterator
{
	assert(iterator->next = hash_iterator_next);

	struct hash_iterator *it = hash_iterator(iterator);


	it->base.next_equal = 0; /* Should not be used if not positioned. */
	it->h_pos = mh_begin(int64_hash);
	it->hash = (struct mh_i32ptr_t *) int64_hash;
}

- (void) initIterator: (struct iterator *) iterator :(void *) field
			:(int) part_count
{
	assert(iterator->next = hash_iterator_next);
	assert(part_count == 1);
	(void) part_count;

	struct hash_iterator *it = hash_iterator(iterator);

	u32 field_size = load_varint32(&field);
	u64 num = *(u64 *)field;

	if (field_size != 8)
		tnt_raise(IllegalParams, :"key is not u64");

	it->base.next_equal = iterator_first_equal;
	it->h_pos = mh_i64ptr_get(int64_hash, num);
	it->hash = (struct mh_i32ptr_t *) int64_hash;
}
@end

/* }}} */

/* {{{ HashStrIndex ***********************************************/

@interface HashStrIndex: HashIndex {
	 struct mh_lstrptr_t *str_hash;
};
@end

@implementation HashStrIndex
- (void) free
{
	mh_lstrptr_destroy(str_hash);
	[super free];
}

- (void) enable
{
	enabled = true;
	str_hash = mh_lstrptr_init();
}

- (size_t) size
{
	return mh_size(str_hash);
}

- (struct box_tuple *) find: (void *) field
{
	struct box_tuple *ret = NULL;
	mh_int_t k = mh_lstrptr_get(str_hash, field);

	if (k != mh_end(str_hash))
		ret = mh_value(str_hash, k);
#ifdef DEBUG
	u32 field_size = load_varint32(&field);
	say_debug("HashStrIndex find(self:%p, key:(%i)'%.*s') = %p",
		  self, field_size, field_size, (u8 *)field, ret);
#endif
	return ret;
}

- (void) remove: (struct box_tuple *) tuple
{
	void *field = tuple_field(tuple, key_def.parts[0].fieldno);

	mh_int_t k = mh_lstrptr_get(str_hash, field);
	if (k != mh_end(str_hash))
		mh_lstrptr_del(str_hash, k);
#ifdef DEBUG
	u32 field_size = load_varint32(&field);
	say_debug("HashStrIndex remove(self:%p, key:'%.*s')",
		  self, field_size, (u8 *)field);
#endif
}

- (void) replace: (struct box_tuple *) old_tuple
	:(struct box_tuple *) new_tuple
{
	void *field = tuple_field(new_tuple, key_def.parts[0].fieldno);

	if (field == NULL)
		tnt_raise(ClientError, :ER_NO_SUCH_FIELD,
			  key_def.parts[0].fieldno);

	if (old_tuple != NULL) {
		void *old_field = tuple_field(old_tuple,
					      key_def.parts[0].fieldno);
		mh_int_t k = mh_lstrptr_get(str_hash, old_field);
		if (k != mh_end(str_hash))
			mh_lstrptr_del(str_hash, k);
	}

	mh_lstrptr_put(str_hash, field, new_tuple, NULL);
#ifdef DEBUG
	u32 field_size = load_varint32(&field);
	say_debug("HashStrIndex replace(self:%p, old_tuple:%p, tuple:%p) key:'%.*s'",
		  self, old_tuple, new_tuple, field_size, (u8 *)field);
#endif
}

- (void) initIterator: (struct iterator *) iterator
{
	assert(iterator->next = hash_iterator_next);

	struct hash_iterator *it = hash_iterator(iterator);

	it->base.next_equal = 0; /* Should not be used if not positioned. */
	it->h_pos = mh_begin(str_hash);
	it->hash = (struct mh_i32ptr_t *) str_hash;
}

- (void) initIterator: (struct iterator *) iterator :(void *) key
			:(int) part_count
{
	assert(iterator->next = hash_iterator_next);
	assert(part_count== 1);
	(void) part_count;

	struct hash_iterator *it = hash_iterator(iterator);

	it->base.next_equal = iterator_first_equal;
	it->h_pos = mh_lstrptr_get(str_hash, key);
	it->hash = (struct mh_i32ptr_t *) str_hash;
}
@end

/* }}} */

void
build_indexes(void)
{
	for (u32 n = 0; n < BOX_SPACE_MAX; ++n) {
		if (space[n].enabled == false)
			continue;
		/* A shortcut to avoid unnecessary log messages. */
		if (space[n].index[1] == nil)
			continue; /* no secondary keys */
		say_info("Building secondary keys in space %" PRIu32 "...", n);
		Index *pk = space[n].index[0];
		for (u32 idx = 1;; idx++) {
			Index *index = space[n].index[idx];
			if (index == nil)
				break;

			if (index->type != TREE)
				continue;
			[(TreeIndex*) index build: pk];
		}
		say_info("Space %"PRIu32": done", n);
	}
}

/**
 * vim: foldmethod=marker
 */
