// 验证：能耗计数是否为单调累计值（需要两次采样做差分才能得到"实时功率"）
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <libproc.h>
#include <sys/sysctl.h>
#include <sys/resource.h>

#define MAXP 1200
typedef struct { pid_t pid; uint64_t enj, penj, billed; char nm[64]; } rec_t;

static int collect(rec_t *out) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0) return 0;
    struct kinfo_proc *kp = malloc(len);
    if (sysctl(mib, 4, kp, &len, NULL, 0) != 0) { free(kp); return 0; }
    int n = (int)(len / sizeof(struct kinfo_proc));
    int cnt = 0;
    for (int i = 0; i < n && cnt < MAXP; i++) {
        pid_t pid = kp[i].kp_proc.p_pid;
        if (pid <= 0) continue;
        struct rusage_info_v6 ri;
        memset(&ri, 0, sizeof(ri));
        if (proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)&ri) != 0) continue;
        out[cnt].pid = pid;
        out[cnt].enj = ri.ri_energy_nj;
        out[cnt].penj = ri.ri_penergy_nj;
        out[cnt].billed = ri.ri_billed_energy;
        char b[64]; if (proc_name(pid, b, sizeof(b)) <= 0) snprintf(b, sizeof(b), "?");
        snprintf(out[cnt].nm, sizeof(out[cnt].nm), "%s", b);
        cnt++;
    }
    free(kp);
    return cnt;
}

int main(int argc, char **argv) {
    int secs = (argc > 1) ? atoi(argv[1]) : 5;
    rec_t a[MAXP], b[MAXP];
    int na = collect(a);
    printf("采样窗口 = %d 秒, 第一次采样 %d 个进程...\n\n", secs, na);
    sleep(secs);
    int nb = collect(b);

    printf("PID      NAME                            delta_energy_nj      -> mW       delta_billed(uJ)\n");
    printf("-------------------------------------------------------------------------------------------\n");
    int shown = 0;
    // 简单排序：对本次 delta 做插入式输出
    typedef struct { pid_t pid; double dnj; uint64_t dbilled; char nm[64]; } d_t;
    d_t ds[MAXP]; int dc = 0;
    for (int i = 0; i < nb; i++) {
        for (int j = 0; j < na; j++) {
            if (a[j].pid == b[i].pid) {
                if (b[i].enj > a[j].enj) {
                    ds[dc].pid = b[i].pid;
                    ds[dc].dnj = (double)(b[i].enj - a[j].enj);
                    ds[dc].dbilled = (b[i].billed > a[j].billed) ? (b[i].billed - a[j].billed) : 0;
                    snprintf(ds[dc].nm, sizeof(ds[dc].nm), "%s", b[i].nm);
                    dc++;
                }
                break;
            }
        }
    }
    for (int x = 0; x < dc; x++)
        for (int y = x + 1; y < dc; y++)
            if (ds[y].dnj > ds[x].dnj) { d_t t = ds[x]; ds[x] = ds[y]; ds[y] = t; }

    for (int i = 0; i < dc && i < 15; i++, shown++) {
        printf("%-8d %-30s %16.0f %8.2f mW %12llu\n",
               ds[i].pid, ds[i].nm, ds[i].dnj,
               ds[i].dnj / 1e6 / secs * 1000.0,
               (unsigned long long)(ds[i].dbilled / 1000));
    }
    printf("-------------------------------------------------------------------------------------------\n");
    printf("有能耗增量的进程数 = %d / 采样 %d\n", dc, nb);
    printf("说明: delta 为 0 的进程说明计数未变化(空闲)，即该计数器是单调累计量，需差分求速率。\n");
    return 0;
}
