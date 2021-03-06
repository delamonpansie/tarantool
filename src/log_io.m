/*
 * Copyright (C) 2010-2016 Mail.RU
 * Copyright (C) 2010-2016,2021 Yury Vostrikov
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

#import <util.h>
#import <log_io.h>
#import <fiber.h>
#import <palloc.h>
#import <say.h>
#import <pickle.h>
#import <tbuf.h>
#import <shard.h>

#include <third_party/crc32.h>

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/file.h>

#if !HAVE_DECL_FDATASYNC
extern int fdatasync(int fd);
#endif

#if !HAVE_MEMRCHR
/* os x doesn't have memrchr */
static void *
memrchr(const void *s, int c, size_t n)
{
    const unsigned char *cp;

    if (n != 0) {
        cp = (unsigned char *)s + n;
        do {
            if (*(--cp) == (unsigned char)c)
                return((void *)cp);
        } while (--n != 0);
    }
    return(NULL);
}
#endif

const u64 default_cookie = 0;
const u32 default_version = 12;
const char *v12 = "0.12\n";
const char *snap_mark = "SNAP\n";
const char *xlog_mark = "XLOG\n";
const char *inprogress_suffix = ".inprogress";
const u32 marker = 0xba0babed;
const u32 eof_marker = 0x10adab1e;
Class version3 = nil;
Class version4 = nil;
Class version11 = nil;


struct row_v12 *
dummy_row(i64 lsn, i64 scn, u16 tag)
{
	struct row_v12 *r = palloc(fiber->pool, sizeof(struct row_v12));

	r->lsn = lsn;
	r->scn = scn;
	r->tm = ev_now();
	r->tag = tag;
	r->len = 0;
	r->data_crc32c = crc32c(0, (unsigned char *)"", 0);
	r->header_crc32c = crc32c(0, (unsigned char *)r + sizeof(r->header_crc32c),
				  sizeof(*r) - sizeof(r->header_crc32c));
	return r;
}

const char *
xlog_tag_to_a(u16 tag)
{
	static char buf[32];
	char *p = buf;
	u16 tag_type = tag & ~TAG_MASK;
	tag &= TAG_MASK;

	if (tag == 0)
		return "nil";

	switch (tag_type) {
	case TAG_SNAP: p += sprintf(p, "snap/"); break;
	case TAG_WAL: p += sprintf(p, "wal/"); break;
	case TAG_SYS: p += sprintf(p, "sys/"); break;
	default: p += sprintf(p, "%i/", tag_type >> TAG_SIZE);
	}

	switch (tag) {
	case snap_initial:	strcat(p, "snap_initial"); break;
	case snap_data:		strcat(p, "snap_data"); break;
	case snap_final:	strcat(p, "snap_final"); break;
	case wal_data:		strcat(p, "wal_data"); break;
	case wal_final:		strcat(p, "wal_final"); break;
	case shard_create:	strcat(p, "shard_create"); break;
	case shard_alter:	strcat(p, "shard_alter"); break;
	case shard_final:	strcat(p, "shard_final"); break;
	case run_crc:		strcat(p, "run_crc"); break;
	case nop:		strcat(p, "nop"); break;
	case raft_append:	strcat(p, "raft_append"); break;
	case raft_commit:	strcat(p, "raft_commit"); break;
	case raft_vote:		strcat(p, "raft_vote"); break;
	case tlv:		strcat(p, "tlv"); break;
	default:
		if (tag < user_tag)
			sprintf(p, "sys%i", tag);
		else
			sprintf(p, "usr%i", tag >> 5);
	}
	return buf;
}

static char *
set_file_buf(FILE *fd, const int bufsize)
{
	char	*vbuf;

	vbuf = xmalloc(bufsize);
	setvbuf(fd, vbuf, _IOFBF, bufsize);

	return vbuf;
}

@implementation XLog
- (bool) eof { return eof; }
- (u32) version { return 0; }
- (i64) last_read_lsn { return last_read_lsn; }

- (XLog *)
init_filename:(const char *)filename_
           fd:(FILE *)fd_
          dir:(XLogDir *)dir_
	  vbuf:(char*)vbuf_
{
	[super init];
	filename = strdup(filename_);
	fd = fd_;
	mode = LOG_READ;
	dir = dir_;
	vbuf = vbuf_;

	tag_mask = TAG_WAL;
	offset = ftello(fd);

	wet_rows_offset_size = 16;
	wet_rows_offset = xmalloc(wet_rows_offset_size * sizeof(*wet_rows_offset));
	return self;
}

+ (XLog *)
open_for_read_filename:(const char *)filename dir:(XLogDir *)dir
{
	char filetype_[32], version_[32];
	XLog *l = nil;
	FILE *fd;
	char *fbuf;

	if ((fd = fopen(filename, "r")) == NULL)
		return nil; /* no cleanup needed */
	/* libc will try prepread sizeof(vbuf) bytes on every fseeko,
	   so no reason to make vbuf particulary large */
	fbuf = set_file_buf(fd, 64 * 1024);

	if (fgets(filetype_, sizeof(filetype_), fd) == NULL ||
	    fgets(version_, sizeof(version_), fd) == NULL)
	{
		if (feof(fd))
			say_error("unexpected EOF reading %s", filename);
		else
			say_syserror("can't read header of %s", filename);
		goto error;
	}

	if (dir != NULL && strncmp(dir->filetype, filetype_, sizeof(filetype_)) != 0) {
		say_error("filetype mismatch of %s", filename);
		goto error;
	}

	if (strcmp(version_, v12) != 0) {
		say_error("bad version `%s' of %s", version_, filename);
		goto error;
	}

	l = [[XLog12 alloc] init_filename:filename fd:fd dir:dir vbuf:fbuf];
	if ([l read_header] < 0) {
		if (feof(fd))
			say_error("unexpected EOF reading %s", filename);
		else
			say_syserror("can't read header of %s", filename);
		[l free]; /* will do correct cleanup */
		return nil;
	}

	return l;

error:
	fclose(fd);
	free(fbuf);
	return nil;
}


- (id)
free
{
	ev_stat_stop(&stat);

	if (mode == LOG_READ && rows == 0 && access(filename, F_OK) == 0) {
		panic("no valid rows were read");
	}

	if (fd) {
		if (mode == LOG_WRITE)
			[self write_eof_marker];
		[self close];
	}

	free(wet_rows_offset);
	free(filename);
	free(vbuf);
	return [super free];
}

- (size_t)
rows
{
	return rows + wet_rows;
}

- (int)
inprogress_rename
{
	int result = 0;

	char *final_filename = strdup(filename);
	char *suffix = strrchr(final_filename, '.');
	assert(strcmp(suffix, inprogress_suffix) == 0);
	*suffix = 0;

	if (rename(filename, final_filename) != 0) {
		say_syserror("can't rename %s to %s", filename, final_filename);
		result = -1;
	} else {
		assert(inprogress);
		inprogress = 0;
		*(strrchr(filename, '.')) = 0;
	}

	free(final_filename);
	if (result >= 0) {
		result = [dir sync];
		if (result < 0)
			say_syserror("can't fsync dir");
	}
	return result;
}

- (int)
close
{
	if (fd == NULL)
		return 0;
	if (fclose(fd) < 0) {
		say_syserror("can't close");
		return -1;
	}
	fd = NULL;
	return 0;
}

- (int)
write_eof_marker
{
	assert(mode == LOG_WRITE);
	assert(fd != NULL);

	if (fwrite(&eof_marker, sizeof(eof_marker), 1, fd) != 1) {
		say_syserror("can't write eof_marker");
		return -1;
	}

	if ([self flush] == -1)
		return -1;

	if ([self close] == -1)
		return -1;
	return 0;
}

- (int)
flush
{
	if (fflush(fd) < 0) {
		say_syserror("fflush");
		/* prevent silent drop of wet rows.
		   it's required to call [confirm_write] in case of wet file */
		assert(wet_rows == 0);
		return -1;
	}
	if (fsync(fileno(fd)) < 0) {
		say_syserror("fsync");
		return -1;
	}
	return 0;
}

- (void)
fadvise_dont_need
{
#if HAVE_POSIX_FADVISE
	off_t end = ftello(fd);
	/* на всякий случай :-) */
	if (end < 128*1024 + 4096)
		return;
	end -= 128*1024 + end % 4096;
	posix_fadvise(fileno(fd), 0, end, POSIX_FADV_DONTNEED);
#endif
}

- (void)
write_header
{
	assert(false);
}

- (int)
read_header
{
        char buf[256];
        char *r;
        for (;;) {
                r = fgets(buf, sizeof(buf), fd);
                if (r == NULL) {
			say_syserror("fgets");
			return -1;
		}

                if (strcmp(r, "\n") == 0 || strcmp(r, "\r\n") == 0)
                        break;
        }
        return 0;
}

- (struct row_v12 *)
read_row
{
	return NULL;
}

- (marker_desc_t)
marker_desc
{
	return (marker_desc_t){
		.marker = (u64)marker,
		.eof = (u64)eof_marker,
		.size = 4,
		.eof_size = 4
	};
}

- (struct row_v12 *)
fetch_row
{
	struct row_v12 *row;
	u64 magic, magic_shift;
	off_t marker_offset = 0, good_offset, eof_offset;
	marker_desc_t mdesc = [self marker_desc];

	magic = 0;
	magic_shift = (mdesc.size - 1) * 8;
	good_offset = ftello(fd);

restart:

	/*
	 * reset stream status if we reached eof before,
	 * subsequent fread() call could cache (at least on
	 * FreeBSD) eof cache status
	 */
	if (feof(fd))
		clearerr(fd);

	if (marker_offset > 0)
		fseeko(fd, marker_offset + 1, SEEK_SET);

	say_trace("%s: start offt %08" PRIofft, __func__, ftello(fd));
	if (fread(&magic, mdesc.size, 1, fd) != 1)
		goto eof;

	while (magic != mdesc.marker) {
		int c = fgetc(fd);
		if (c == EOF)
			goto eof;
		magic >>= 8;
		magic |= ((u64)c & 0xff) << magic_shift;
	}
	marker_offset = ftello(fd) - mdesc.size;
	if (good_offset != marker_offset)
		say_warn("skipped %" PRIofft " bytes after %08" PRIofft " offset",
			 marker_offset - good_offset, good_offset);
	say_trace("	magic found at %08" PRIofft, marker_offset);

	row = [self read_row];

	if (row == NULL) {
		if (feof(fd))
			goto eof;
		say_warn("failed to read row");
		clearerr(fd);
		goto restart;
	}

	++rows;
	last_read_lsn = row->lsn;
	return row;
eof:
	eof_offset = ftello(fd);
	if (eof_offset == good_offset + mdesc.eof_size) {
		if (mdesc.eof_size == 0) {
			eof = 1;
			return NULL;
		}

		fseeko(fd, good_offset, SEEK_SET);

		magic = 0;
		/* reset stream status if we reached eof before */
		if (feof(fd))
			clearerr(fd);

		if (fread(&magic, mdesc.eof_size, 1, fd) != 1) {
			fseeko(fd, good_offset, SEEK_SET);
			return NULL;
		}

		if (magic != mdesc.eof) {
			fseeko(fd, good_offset, SEEK_SET);
			return NULL;
		}

		eof = 1;
		return NULL;
	}
	/* libc will try prepread sizeof(vbuf) bytes on fseeko,
	   and this behavior will trash system on continous log follow mode
	   since every fetch_row will result in seek + read(sizeof(vbuf)) */
	if (eof_offset != good_offset)
		fseeko(fd, good_offset, SEEK_SET);
	return NULL;
}

- (void)
follow:(follow_cb *)cb data:(void *)data
{
	if (ev_is_active(&stat))
		return;

	if (cb == NULL) {
		ev_stat_stop(&stat);
		return;
	}

	ev_stat_init(&stat, cb, filename, 0.);
	stat.interval = (ev_tstamp)cfg.wal_dir_rescan_delay / 10;
	stat.data = data;
	ev_stat_start(&stat);
}

- (i64)
next_lsn
{
	assert(next_lsn != 0);
	if ([dir isKindOf:[SnapDir class]])
		return next_lsn;
	return next_lsn + wet_rows;
}

- (void)
append_successful:(size_t)bytes
{
	if (no_wet) {
		rows++;
		return;
	}

	if (wet_rows_offset_size == wet_rows) {
		wet_rows_offset_size *= 2;
		wet_rows_offset = xrealloc(wet_rows_offset,
					   wet_rows_offset_size * sizeof(*wet_rows_offset));
	}

	off_t prev_offt = wet_rows == 0 ? offset : wet_rows_offset[wet_rows - 1];
	wet_rows_offset[wet_rows] = prev_offt + bytes;
	wet_rows++;
}

static void
assert_row(const struct row_v12 *row)
{
	(void)row;
	assert(row->tag & ~TAG_MASK);
	assert(row->len > 0); /* fwrite() has funny behavior if size == 0 */
}

- (const struct row_v12 *)
append_row:(struct row_v12 *)row data:(const void *)data
{
	(void)row; (void)data;
	panic("%s: virtual", __func__);
}

- (const struct row_v12 *)
append_row:(const void *)data len:(u32)len scn:(i64)scn tag:(u16)tag
{
	static struct row_v12 row;
	row = (struct row_v12){ .scn = scn,
				.tm = ev_now(),
				.tag = tag,
				.len = len };

	return [self append_row:&row data:data];
}

- (const struct row_v12 *)
append_row:(const void *)data len:(u32)len shard:(Shard *)shard tag:(u16)tag
{
	static struct row_v12 row;
	row = (struct row_v12){ .scn = shard->scn,
				.tm = ev_now(),
				.tag = tag,
				.shard_id = shard->id,
				.len = len };

	return [self append_row:&row data:data];
}

- (i64)
confirm_write
{
	assert(next_lsn != 0);
	assert(mode == LOG_WRITE);
	/* XXX teodor
	 * assert(!no_wet);
	 */

	off_t tail;

	if (wet_rows == 0)
		goto exit;

	if (fflush(fd) < 0) {
		say_syserror("fflush");

		tail = ftello(fd);

		say_trace("%s offset:%llu tail:%lli", __func__, (long long)offset, (long long)tail);

		off_t confirmed_offset = 0;
		for (int i = 0; i < wet_rows; i++) {
			if (wet_rows_offset[i] > tail) {
				say_error("failed to sync %lli rows", (long long)(wet_rows - i));
				if (confirmed_offset) {
					if (fseeko(fd, confirmed_offset, SEEK_SET) == -1)
						say_syserror("fseeko");
					if (ftruncate(fileno(fd), confirmed_offset) == -1)
						say_syserror("ftruncate");
				}
				break;
			}
			confirmed_offset = wet_rows_offset[i];
			say_trace("confirmed offset %lli", (long long)confirmed_offset);
			next_lsn++;
			rows++;
		}
	} else {
		tail = wet_rows_offset[wet_rows - 1];
		next_lsn += wet_rows;
		rows += wet_rows;
	}
#if HAVE_SYNC_FILE_RANGE
	sync_bytes += tail - offset;
	if (unlikely(sync_bytes > 32 * 4096)) {
		sync_file_range(fileno(fd), sync_offset, 0, SYNC_FILE_RANGE_WRITE);
		sync_offset += sync_bytes;
		sync_bytes = 0;
	}
#endif
	bytes_written += tail - offset;
	offset = tail;
	wet_rows = 0;
exit:
	return next_lsn - 1;
}

- (int)
fileno
{
	return fileno(fd);
}
@end


@implementation XLog12
- (u32) version { return 12; }

- (int)
read_header
{
        char buf[256];
        char *r;
        for (;;) {
                r = fgets(buf, sizeof(buf), fd);
                if (r == NULL)
                        return -1;
		if (strcmp(r, "\n") == 0 || strcmp(r, "\r\n") == 0)
                        break;
        }
        return 0;
}

- (void)
write_header
{
	fwrite(dir->filetype, strlen(dir->filetype), 1, fd);
	fwrite(v12, strlen(v12), 1, fd);
	fprintf(fd, "Created-by: octopus\n");
	fprintf(fd, "Octopus-version: %s\n", octopus_version());
}

- (void)
write_header_scn:(const i64 *)scn
{
	if (scn[0])
		fprintf(fd, "SCN: %"PRIi64"\n", scn[0] + 1);
	for (int i = 0; i < MAX_SHARD; i++)
		if (scn[i])
			fprintf(fd, "SCN-%i: %"PRIi64"\n", i, scn[i] + 1);
}


- (struct row_v12 *)
read_row
{
	struct tbuf *m = tbuf_alloc(fiber->pool);

	u32 header_crc, data_crc;

	tbuf_reserve(m, sizeof(struct row_v12));
	if (fread(m->ptr, sizeof(struct row_v12), 1, fd) != 1) {
		if (ferror(fd))
			say_error("fread error");
		return NULL;
	}

	tbuf_append(m, NULL, offsetof(struct row_v12, data));

	/* header crc32c calculated on all fields before data_crc32c> */
	header_crc = crc32c(0, m->ptr + offsetof(struct row_v12, lsn),
			    sizeof(struct row_v12) - offsetof(struct row_v12, lsn));

	if (row_v12(m)->header_crc32c != header_crc) {
		say_error("header crc32c mismatch");
		return NULL;
	}

	tbuf_reserve(m, tbuf_len(m) + row_v12(m)->len);
	if (fread(row_v12(m)->data, row_v12(m)->len, 1, fd) != 1) {
		if (ferror(fd))
			say_error("fread error");
		return NULL;
	}

	tbuf_append(m, NULL, row_v12(m)->len);

	data_crc = crc32c(0, row_v12(m)->data, row_v12(m)->len);
	if (row_v12(m)->data_crc32c != data_crc) {
		say_error("data crc32c mismatch");
		return NULL;
	}

	if (tbuf_len(m) < sizeof(struct row_v12)) {
		say_error("row is too short");
		return NULL;
	}

	say_trace("%s: LSN:%" PRIi64, __func__, row_v12(m)->lsn);

	return m->ptr;
}

- (const struct row_v12 *)
append_row:(struct row_v12 *)row data:(const void *)data
{
	if (!header_written) {
		if (fputc('\n', fd) == EOF)
			return NULL;
		if ((offset = ftello(fd)) < 0 || ferror(fd))
		return NULL;
		header_written = true;
	}

	if ((row->tag & ~TAG_MASK) == 0)
		row->tag |= tag_mask;

	assert_row(row);

	row->lsn = [self next_lsn];
	row->scn = row->scn ?: row->lsn;
	row->data_crc32c = crc32c(0, data, row->len);
	row->header_crc32c = crc32c(0, (unsigned char *)row + sizeof(row->header_crc32c),
				   sizeof(*row) - sizeof(row->header_crc32c));

#if LOG_IO_ERROR_INJECT
	const void *ptr = data;
	int len = row->len;
	while ((ptr = memmem(ptr, len, "sleep", 5))) {
		sleep(3);
		ptr += 5;
		len = row->len - (ptr - data);
	}
	if (memmem(data, row->len, "error", 5))
		return NULL;
#endif

	if (fwrite(&marker, sizeof(marker), 1, fd) != 1 ||
	    fwrite(row, sizeof(*row), 1, fd) != 1 ||
	    fwrite(data, row->len, 1, fd) != 1)
	{
		say_syserror("fwrite");
		return NULL;
	}

	[self append_successful:sizeof(marker) + sizeof(*row) + row->len];
	return row;
}
@end

@implementation XLogDir
- (id)
init_dirname:(const char *)dirname_
{
        dirname = dirname_;
	xlog_class = [XLog12 class];
        return self;
}

- (int)
sync
{
	extern int xlog_dir_sync(struct XLogDirRS *);
	return xlog_dir_sync(rs_dir);
}

- (id)
free
{
	extern int xlog_dir_free(struct XLogDirRS *);
	xlog_dir_free(rs_dir);
	rs_dir = NULL;
	return [super free];
}

- (int)
lock
{
	extern int xlog_dir_lock(struct XLogDirRS *);
	return xlog_dir_lock(rs_dir);
}

- (i64)
greatest_lsn
{
	extern i64 xlog_dir_greatest_lsn(struct XLogDirRS *);
	return xlog_dir_greatest_lsn(rs_dir);
}

- (const char *)
format_filename:(i64)lsn suffix:(const char *)extra_suffix
{
	static char filename[PATH_MAX + 1];
	snprintf(filename, sizeof(filename),
		 "%s/%020" PRIi64 "%s%s",
		 dirname, lsn, suffix, extra_suffix);
	return filename;
}

- (const char *)
format_filename:(i64)lsn
{
	return [self format_filename:lsn suffix:""];
}


- (XLog *)
open_for_read:(i64)lsn
{
	const char *filename = [self format_filename:lsn];
	XLog *xlog = [XLog open_for_read_filename:filename dir:self];
	if (xlog)
		xlog->lsn = lsn;
	return xlog;
}

int allow_snap_overwrite = 0;
- (XLog *)
open_for_write:(i64)lsn
{
        XLog *l = nil;
        FILE *file = NULL;
        assert(lsn > 0);
	char *fbuf = NULL;

	const char *final_filename = [self format_filename:lsn];
	if (!allow_snap_overwrite && access(final_filename, F_OK) == 0) {
		errno = EEXIST;
		say_error("failed to create '%s': file already exists", final_filename);
		goto error;
	}

	const char *filename = [self format_filename:lsn suffix:inprogress_suffix];

	/* .inprogress file can't contain confirmed records, overwrite it silently */
	file = fopen(filename, "w");
	if (file == NULL) {
		say_syserror("fopen of %s for writing failed", filename);
		goto error;
	}
	fbuf = set_file_buf(file, 1024 * 1024);

	l = [[xlog_class alloc] init_filename:filename fd:file dir:self vbuf:fbuf];

	/* reset local variables: they are included in l */
	fbuf = NULL;
	file = NULL;

	l->next_lsn = lsn;
	l->mode = LOG_WRITE;
	l->inprogress = 1;

	[l write_header];
	return l;
      error:
        if (file != NULL)
                fclose(file);
	free(fbuf);
        [l free];
	return NULL;
}

XLog *
xlog_dir_open_for_read(XLogDir *dir, i64 lsn, const char *filename)
{
	XLog *xlog = [XLog open_for_read_filename:filename dir:dir];
	if (xlog)
		xlog->lsn = lsn;
	return xlog;
}

- (XLog *)
find_with_lsn:(i64)lsn
{
	extern struct XLog *xlog_dir_find_with_lsn(struct XLogDirRS *, i64);
	return xlog_dir_find_with_lsn(rs_dir, lsn);
}

- (XLog *)
find_with_scn:(i64)scn shard:(int)shard_id
{
	extern struct XLog *xlog_dir_find_with_scn(struct XLogDirRS *, i32, i64);
	return xlog_dir_find_with_scn(rs_dir, shard_id, scn);
}
@end

@implementation WALDir
- (XLogDir *)
init_dirname:(const char *)dirname_
{
        if ((self = [super init_dirname:dirname_])) {
		filetype = xlog_mark;
		suffix = ".xlog";
		extern struct XLogDirRS *xlog_dir_new_waldir(const char *, XLogDir *);
		rs_dir = xlog_dir_new_waldir(dirname_, self);
	}
	return self;
}
@end

@interface Snap12 : XLog12 {
	size_t bytes;
	ev_tstamp step_ts, last_ts;
}@end

@implementation Snap12
- (XLog *)
init_filename:(const char *)filename_
           fd:(FILE *)fd_
          dir:(XLogDir *)dir_
	  vbuf:(char*)vbuf_
{
	[super init_filename:filename_ fd:fd_ dir:dir_ vbuf:vbuf_];
	tag_mask = TAG_SNAP;
	return self;
}

- (const struct row_v12 *)
append_row:(struct row_v12 *)row12 data:(const void *)data
{
	const struct row_v12 *ret = [super append_row:row12 data:data];
	if (ret == NULL)
		return NULL;

	bytes += sizeof(*row12) + row12->len;

	if (rows & 31)
		return ret;

	ev_now_update();
	if (last_ts == 0) {
		last_ts = ev_now();
		step_ts = ev_now();
	}

	const int io_rate_limit = cfg.snap_io_rate_limit * 1024 * 1024;
	if (io_rate_limit <= 0) {
		if (ev_now() - step_ts > 0.1) {
			if ([self flush] < 0)
				return NULL;
			if (cfg.snap_fadvise_dont_need)
				[self fadvise_dont_need];
			ev_now_update();
			step_ts = ev_now();
		}
		return ret;
	}

	if (ev_now() - step_ts > 0.02) {
		double delta = ev_now() - last_ts;
		size_t bps = bytes / delta;

		if (bps > io_rate_limit) {
			if ([self flush] < 0)
				return NULL;
			if (cfg.snap_fadvise_dont_need)
				[self fadvise_dont_need];
			ev_now_update();
			delta = ev_now() - last_ts;
			bps = bytes / delta;
		}

		if (bps > io_rate_limit) {
			double sec = delta * (bps - io_rate_limit) / io_rate_limit;
			usleep(sec * 1e6);
			ev_now_update();
		}
		step_ts = ev_now();
	}

	if (ev_now() > last_ts + 1) {
		bytes = 0;
		last_ts = step_ts = ev_now();
	}

	return ret;
}

#if HAVE_POSIX_FADVISE
- (int)
close
{
	if (fd)
		posix_fadvise(fileno(fd), 0, ftello(fd), POSIX_FADV_DONTNEED);
	return [super close];
}
#endif
@end


@implementation SnapDir
- (id)
init_dirname:(const char *)dirname_
{
        if ((self = [super init_dirname:dirname_])) {
		filetype = snap_mark;
		suffix = ".snap";
		extern struct XLogDirRS *xlog_dir_new_snapdir(const char *, XLogDir *);
		rs_dir = xlog_dir_new_snapdir(dirname_, self);
	}
	// rate limiting only v12 snapshots
	if (xlog_class == [XLog12 class])
		xlog_class = [Snap12 class];
        return self;
}
@end

register_source();
