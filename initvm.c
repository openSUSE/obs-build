/*
 * NAME
 *	initvm - init for qemu, setup binfmt_misc launch build
 *	
 * SYNOPSIS
 *	initvm
 *
 * DESCRIPTION
 *	This is the kernel init script for virtual machines which will
 *	be running executables for an embedded (non-native)
 *	architecture. It registers binfmt_misc handlers for qemu and
 *	executes the build script, and tests many assumptions.
 *
 * FILES
 *	/.build/qemu-reg
 *		text file with lines to stuff into the binfmt_misc
 *		filesystem registration file
 *	/.build/build
 *		build script to execute once binfmts are set up
 *
 * AUTHOR
 *      Copyright (c) 2012 James Perkins <james.perkins@linuxfoundation.org>
 * 	i                  Adrian Schroeter <adrian@suse.de>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 or 3 as
 * published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program (see the file COPYING); if not, write to the
 * Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA
 */

#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdio.h>
#include <unistd.h>

/* to enable debugging, compile with -DDEBUG */
#ifdef DEBUG
#define DBG(x) 		do { x; } while(0)
#else
#define DBG(x)
#endif

/* function return codes */
enum okfail { FAIL=0, OK=1 };

/* qemu registration fields, see kernel/Documentation/binfmt_misc.txt */
enum fields { ignore=0, name, type, offset, magic, mask, interpreter, flags };
const char * const fieldnames[] = {
	"ignore", "name", "type", "offset",
	"magic", "mask", "interpreter", "flags"
};
const int n_fields = 8;

/* files in useful places */
#define SYSFS_BINFMT_MISC	"/proc/sys/fs/binfmt_misc"
#define SYSFS_BINFMT_MISC_REG	"/proc/sys/fs/binfmt_misc/register"
#define SYSFS_BINFMT_MISC_STAT	"/proc/sys/fs/binfmt_misc/status"

/* /usr/lib/build/x paths are copied to /.build inside a virtual machine */
#define BINFMT_REGF_0		"/.build/qemu-reg"
#define BINFMT_REGF_1		"/usr/lib/build/qemu-reg"
#define BUILD			"/.build/build"

/* useful constant arrays */
static char *rx_files[] = { "/proc", "/proc/sys", "/proc/sys/fs",
	 SYSFS_BINFMT_MISC, NULL };
static char *w_files[] = { SYSFS_BINFMT_MISC_REG, NULL };

static char* const args[] = { BUILD, NULL };

/* test access modes for files, return OK or FAIL */
enum okfail test_access_files(char *files[], int mode, const char *errstr)
{
	int i;

	for (i = 0; files[i] != NULL; i++) {
		if (access(files[i], mode) != 0) {
			fprintf(stderr, "%s: %s: fails test\n",
				files[i], errstr);
			return FAIL;
		}
	}

	return OK;
}

/* find a string in the given file, return OK or FAIL */
enum okfail strfile(const char *filename, const char *string)
{
	char buf[BUFSIZ];
	FILE *fp;
	enum okfail found = FAIL;

	fp = fopen(filename, "r");
	if (fp == NULL)
	{
		perror(filename);
		return FAIL;
	}
	while (fgets(buf, sizeof(buf), fp) != NULL)
	{
		if (strcmp(buf, string) == 0) {
			found = OK;
			break;
		}

	}
	(void)fclose(fp);

	return found;
}

/* write the file with given string, return OK or FAIL */
enum okfail write_file_string(const char *filename, const char *string)
{
	int fd;

	if ((fd = open(filename, O_WRONLY)) == -1)
	{
		perror(filename);
		return FAIL;
	}

	if (write(fd, string, strlen(string)) == -1)
	{
		perror("write");
		fprintf(stderr, "%s: write failed\n", filename);
		close(fd);
		return FAIL;
	}

	close(fd);
	return OK;
}

#ifdef DEBUG
/* dump contents of the file to stderr, return OK or FAIL */
enum okfail dump_file(char *path)
{
	FILE *fp;
	char buf[BUFSIZ];

	fp = fopen(path, "r");
	if (fp == NULL) {
		perror(path);
		return FAIL;
	}

	while (fgets(buf, sizeof(buf), fp) != NULL)
	{
		fputs(buf, stderr);
	}

	fclose(fp);
	return OK;
}
#endif /* DEBUG */

/* parse datafile and register (to regfile) all binary formats found */
enum okfail binfmt_register(char *datafile, char *regfile)
{
	char buf[BUFSIZ];
	FILE *fp;
	int line;
	struct utsname myuname;
	uname(&myuname);

	fp = fopen(datafile, "r");
	if (fp == NULL)
	{
		perror(datafile);
		return FAIL;
	}

	for (line = 1; fgets(buf, sizeof(buf), fp) != NULL; line++)
	{
		char tokens[BUFSIZ];
		char *s = tokens;
		char *blacklist;
		char *f[n_fields];	/* field content pointers */
		int n;			/* current field */
		char path[BUFSIZ];

		if (buf[0] != ':')	/* non-data input line */
		{
			continue;
		}
		blacklist = strchr(buf, ' ');
		if (blacklist) {
			int skip = 0;
			char *eol;

			*blacklist = '\0';
			blacklist++;

			eol = strchr(blacklist, '\n');
			if (eol)
				*eol = '\0';

			for (n = 0; blacklist != NULL; n++)
			{
				char *bp = strsep(&blacklist, " ");
				if (!strcmp(bp, myuname.machine)) {
#ifdef DEBUG
					fprintf(stderr, " skipping on hostarch %s line %s\n", bp, buf);
#endif /* DEBUG */
					skip = 1;
					break;
				}
			}
			if (skip)
				continue;
		}

		/* copy buf and tokenize :-seperated fields into f[] */
		strcpy(tokens, buf);
		for (n = 0; s != NULL && n < n_fields; n++)
		{
			f[n] = strsep(&s, ":");
		}

#ifdef DEBUG
		int i;
		fprintf(stderr, "DEBUG: line %d, fields %d:\n",  line, n);
		for (i = name; i < n; i++)
		{
			fprintf(stderr, " %s %s\n", fieldnames[i], f[i]);
		}
#endif /* DEBUG */

		if (n == n_fields && s != NULL)
		{
			fprintf(stderr, "%s: line %d: extra fields, ignoring."
				" Content: %s", datafile, line, buf);
			continue;
		}

		if (n < n_fields)
		{
			fprintf(stderr, "%s: line %d: missing fields, ignoring."
				" Content: %s", datafile, line, buf);
			continue;
		}

		int ret;
                /* Is an interpreter for this arch already registered? */
		snprintf(path, sizeof(path), SYSFS_BINFMT_MISC "/%s", f[name]);
		ret=access(path, X_OK);
		if (ret == 0) {
#ifdef DEBUG
			fprintf(stderr, 
				"interpreter for '%s' already registered, ignoring\n",
				f[name]);
#endif /* DEBUG */
			continue;
		}
#ifdef DEBUG
		fprintf(stderr, 
			"registering interpreter for '%s'...\n",
			f[name]);
#endif /* DEBUG */

                /* Does the interpreter exists? */
		ret=access(f[interpreter], X_OK);
		if (ret != 0) {
#ifdef DEBUG
			fprintf(stderr, 
				"%s: line %d: interpreter '%s' not found,"
				" ignoring, return %d\n", datafile, line, f[interpreter], ret);
#endif /* DEBUG */
			continue;
		}

		if (!write_file_string(regfile, buf)) {
			fprintf(stderr, "%s: line %d: write failed."
				" Content: %s\n", datafile, line, buf);
			(void)fclose(fp);
			return FAIL;
		}

		/* verify registration completed correctly */
		snprintf(path, sizeof(path), SYSFS_BINFMT_MISC "/%s", f[name]);

		if (access(path, R_OK) != 0) {
			fprintf(stderr, 
				"%s: line %d: binfmt path not created, content '%s'\n",
				path, line, buf);
			(void)fclose(fp);
			return FAIL;
		}

		DBG(fprintf(stderr, "dumping: %s\n", path));
		DBG(dump_file(path));
	}


	(void)fclose(fp);

	return OK;
}

/* set up/verify binfmt FS support, program more binfmts, and launch build */
int main(int argc, char* argv[], char* env[])
{
	int retval;
	char buf[BUFSIZ];

	/* mount proc filesystem if it isn't already */
	if (mount("proc", "/proc", "proc", MS_MGC_VAL, NULL) == -1) {
		if (errno != EBUSY) {
			perror("mount: /proc");
			exit(1);
		}
	}

	/* try to load binfmt module if present, no big deal if it fails */
	if ((retval = system("/sbin/modprobe binfmt_misc")) != 0) {
		DBG(fprintf(stderr, "modprobe binfmt_misc exit code %d\n",
			retval));
	}

	/* mount binfmt filesystem */
	if (mount("binfmt_misc", SYSFS_BINFMT_MISC, "binfmt_misc", MS_MGC_VAL,
		NULL) == -1) {
		if (errno != EBUSY) {
			perror("mount: binfmt_misc, " SYSFS_BINFMT_MISC);
		}
	}

	/* verify all paths resulting from this are OK */
	if (!test_access_files(rx_files, R_OK|X_OK, "read/search")) {
		exit(1);
	}
	if (!test_access_files(w_files, W_OK, "write")) {
		exit(1);
	}

	if (!strfile("/proc/filesystems", "nodev\tbinfmt_misc\n")) {
		fprintf(stderr,
			"/proc/filesystems: binfmt_misc support missing\n");
		exit(1);
	}

	if (!strfile(SYSFS_BINFMT_MISC_STAT, "enabled\n")) {
		fprintf(stderr,
			"%s: binfmt_misc filesystem support not enabled\n",
			SYSFS_BINFMT_MISC_STAT);
		exit(1);
	}

	if (getenv("BUILD_DIR"))
	    sprintf(buf, "%s/qemu-reg", getenv("BUILD_DIR"));

        if (!buf || !binfmt_register(buf, SYSFS_BINFMT_MISC_REG)) {
		/* setup all done, do the registration */
		if (!binfmt_register(BINFMT_REGF_0, SYSFS_BINFMT_MISC_REG)) {
			fprintf(stderr, "%s: failed. Trying alternate binfmt file\n",
				BINFMT_REGF_0);
			if (!binfmt_register(BINFMT_REGF_1, SYSFS_BINFMT_MISC_REG)) {
				fprintf(stderr, "%s: binfmt registration failed\n",
					BINFMT_REGF_1);
				exit(1);
			}
		}
	}

	/* if we are the init process, start build */
	if (getpid() == 1)
	{
		if (access(BUILD, F_OK) != 0) {
			fprintf(stderr, "%s: build executable missing\n",
				BUILD);
			exit(1);
		}
		if (access(BUILD, X_OK) != 0) {
			fprintf(stderr, "%s: not executable\n", BUILD);
			exit(1);
		}
		execve(BUILD, args, env);
		perror("execve of "BUILD);
		exit(1);
	}

	/* success! */
	exit(0);
}
