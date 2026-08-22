#include <fcntl.h>
#include <sys/syslimits.h>

int usage_ink_fcntl_getpath(int fd, char *buf, int buflen) {
    if (buf == 0 || buflen < PATH_MAX) {
        return -1;
    }
    return fcntl(fd, F_GETPATH, buf);
}
