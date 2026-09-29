// 验证：无 root 权限下能否用 proc_pid_rusage 读取每个进程的能耗
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <libproc.h>
#include <sys/sysctl.h>
#include <sys/resource.h>

static const char *procname(pid_t pid, char *buf, size_t buflen) {
    if (proc_name(pid, buf, (uint32_t)buflen) <= 0) {
        snprintf(buf, buflen, "?");
    }
    return buf;
}

int main(int argc, char **argv) {
    int topN = (argc > 1) ? atoi(argv[1]) : 10;

    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0) { perror("sysctl-len"); return 1; }
    struct kinfo_proc *kp = malloc(len);
    if (sysctl(mib, 4, kp, &len, NULL, 0) != 0) { perror("sysctl"); return 1; }
    int n = (int)(len / sizeof(struct kinfo_proc));

    printf("visible_procs = %d\n", n);
    printf("%-8s %-26s %14s %14s %14s\n", "PID", "NAME", "billed(uJ)", "energy(uJ)", "pen_nj");
    printf("---------------------------------------------------------------------------\n");

    int ok = 0, denied = 0, zero = 0;
    for (int i = 0; i < n; i++) {
        pid_t pid = kp[i].kp_proc.p_pid;
        if (pid <= 0) continue;
        struct rusage_info_v6 ri;
        memset(&ri, 0, sizeof(ri));
        int r = proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)&ri);
        if (r != 0) { denied++; continue; }
        ok++;
        if (ri.ri_billed_energy == 0 && ri.ri_energy_nj == 0) zero++;
    }
    printf("---------------------------------------------------------------------------\n");
    printf("rusage_ok = %d   rusage_denied = %d   zero_energy = %d\n\n", ok, denied, zero);

    // 按 ri_billed_energy 排序输出 TopN
    typedef struct { pid_t pid; uint64_t billed, enj, penj; char nm[64]; } rec_t;
    rec_t *recs = calloc(n, sizeof(rec_t));
    int cnt = 0;
    for (int i = 0; i < n; i++) {
        pid_t pid = kp[i].kp_proc.p_pid;
        if (pid <= 0) continue;
        struct rusage_info_v6 ri;
        memset(&ri, 0, sizeof(ri));
        if (proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)&ri) != 0) continue;
        recs[cnt].pid = pid;
        recs[cnt].billed = ri.ri_billed_energy;
        recs[cnt].enj = ri.ri_energy_nj;
        recs[cnt].penj = ri.ri_penergy_nj;
        char b[64]; procname(pid, b, sizeof(b));
        snprintf(recs[cnt].nm, sizeof(recs[cnt].nm), "%s", b);
        cnt++;
    }
    for (int a = 0; a < cnt; a++)
        for (int b = a + 1; b < cnt; b++)
            if (recs[b].billed > recs[a].billed) { rec_t t = recs[a]; recs[a] = recs[b]; recs[b] = t; }

    printf("TOP %d by ri_billed_energy (nanojoules):\n", topN);
    printf("%-8s %-26s %14s %14s %14s\n", "PID", "NAME", "billed(uJ)", "energy(uJ)", "pen_nj");
    for (int i = 0; i < cnt && i < topN; i++) {
        printf("%-8d %-26s %14llu %14llu %14llu\n",
               recs[i].pid, recs[i].nm,
               (unsigned long long)(recs[i].billed / 1000),
               (unsigned long long)(recs[i].enj / 1000),
               (unsigned long long)recs[i].penj);
    }
    (void)zero;
    return 0;
}
