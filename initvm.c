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
 *	James Perkins <james.perkins@linuxfoundation.org>
 */

#include <sys/mount.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdio.h>

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
		char *f[n_fields];	/* field content pointers */
		int n;			/* current field */
		char path[BUFSIZ];

		if (buf[0] != ':')	/* non-data input line */
		{
			goto skip;
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
			goto skip;
		}

		if (n < n_fields)
		{
			fprintf(stderr, "%s: line %d: missing fields, ignoring."
				" Content: %s", datafile, line, buf);
			goto skip;
		}


		if (access(f[interpreter], X_OK) != 0) {
			fprintf(stderr, 
				"%s: line %d: interpreter '%s' not found,"
				" ignoring\n", datafile, line, f[interpreter]);
			goto skip;
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

skip:
		;
	}


	(void)fclose(fp);

	return OK;
}

/* set up/verify binfmt FS support, program more binfmts, and launch build */
int main(int argc, char* argv[], char* env[])
{
	int retval;

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
		perror("execve");
		exit(1);
	}

	/* success! */
	exit(0);
}
