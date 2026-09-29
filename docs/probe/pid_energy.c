// 验证：单个常驻进程在给定窗口内的真实能耗、CPU 时间与「唤醒次数」。
//
// 为什么不能只看 CPU 时间：菜单栏类常驻应用的空闲能耗主要由**唤醒次数**决定 ——
// 每次被唤醒都会把 CPU 从低功耗态拉出来。一个每 5 秒醒来一次的进程，
// CPU 占用可能只有 0.1%，但能耗远高于一个真正睡着的进程。
// 所以这里同时打印 ri_interrupt_wkups / ri_pkg_idle_wkups。
//
// 编译：clang -O2 -include unistd.h -o pid_energy pid_energy.c
// 运行：./pid_energy <pid|进程名> <秒数>
//
// 字段含义（rusage_info_v6）：
//   ri_energy_nj      该进程消耗的能量（纳焦耳，单调累计）
//   ri_user_time      用户态 CPU 时间（纳秒）
//   ri_system_time    内核态 CPU 时间（纳秒）
//   ri_interrupt_wkups 中断唤醒次数
//   ri_pkg_idle_wkups  空闲唤醒次数
//   ri_instructions   执行的指令数
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <libproc.h>
#include <sys/sysctl.h>

static int find_pid(const char *arg) {
    // 纯数字直接当 pid
    int asPid = atoi(arg);
    if (asPid > 0) return asPid;

    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0) return -1;
    struct kinfo_proc *kp = malloc(len);
    if (!kp) return -1;
    if (sysctl(mib, 4, kp, &len, NULL, 0) != 0) { free(kp); return -1; }
    int n = (int)(len / sizeof(struct kinfo_proc));
    int found = -1;
    for (int i = 0; i < n; i++) {
        pid_t pid = kp[i].kp_proc.p_pid;
        if (pid <= 0) continue;
        char nm[64];
        if (proc_name(pid, nm, sizeof(nm)) <= 0) continue;
        if (strcmp(nm, arg) == 0) { found = pid; break; }   // 取第一个匹配
    }
    free(kp);
    return found;
}

static int snap(pid_t pid, struct rusage_info_v6 *out) {
    memset(out, 0, sizeof(*out));
    return proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)out);
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "用法: %s <pid|进程名> <秒数>\n", argv[0]);
        return 2;
    }
    int secs = atoi(argv[2]);
    if (secs <= 0) secs = 10;

    pid_t pid = find_pid(argv[1]);
    if (pid <= 0) { fprintf(stderr, "找不到进程: %s\n", argv[1]); return 1; }

    char nm[64] = "?";
    proc_name(pid, nm, sizeof(nm));

    struct rusage_info_v6 a;
    if (snap(pid, &a) != 0) {
        fprintf(stderr, "无法读取 pid %d 的 rusage（权限不足或进程已退出）\n", pid);
        return 1;
    }

    printf("监视 %s (pid %d)，窗口 %d 秒…\n", nm, pid, secs);
    fflush(stdout);
    sleep(secs);

    struct rusage_info_v6 b;
    if (snap(pid, &b) != 0) {
        fprintf(stderr, "窗口结束时读不到该进程（可能已退出）\n");
        return 1;
    }

    double dEnergyNJ   = (double)(b.ri_energy_nj - a.ri_energy_nj);
    double dUserNS     = (double)(b.ri_user_time - a.ri_user_time);
    double dSysNS      = (double)(b.ri_system_time - a.ri_system_time);
    double dCPUMS      = (dUserNS + dSysNS) / 1e6;
    double dWkups      = (double)(b.ri_interrupt_wkups - a.ri_interrupt_wkups);
    double dIdleWkups  = (double)(b.ri_pkg_idle_wkups - a.ri_pkg_idle_wkups);
    double dInstr      = (double)(b.ri_instructions - a.ri_instructions);
    double dCycles     = (double)(b.ri_cycles - a.ri_cycles);

    printf("\n--- %s (pid %d) / %d 秒窗口 ---\n", nm, pid, secs);
    // 量纲：ri_energy_nj 是纳焦耳。nJ / 1e6 = mJ；mJ / 秒 = mW。不要再多乘 1000。
    printf("能耗          : %.3f mJ   (平均 %.3f mW)\n",
           dEnergyNJ / 1e6, dEnergyNJ / 1e6 / secs);
    printf("CPU 时间      : %.3f ms  (user %.3f + sys %.3f)\n",
           dCPUMS, dUserNS / 1e6, dSysNS / 1e6);
    printf("CPU 占比      : %.3f %%\n", dCPUMS / 1000.0 / secs * 100.0);
    printf("唤醒（中断）  : %.0f 次  → %.3f 次/秒\n", dWkups, dWkups / secs);
    printf("唤醒（空闲）  : %.0f 次  → %.3f 次/秒\n", dIdleWkups, dIdleWkups / secs);
    printf("指令数        : %.0f  (%.0f 千指令/秒)\n", dInstr, dInstr / 1000.0 / secs);
    printf("周期数        : %.0f\n", dCycles);
    printf("\n单位能耗参考  : %.4f mJ/千指令   （越低说明干的活越划算）\n",
           dInstr > 0 ? (dEnergyNJ / 1e6) / (dInstr / 1000.0) : 0.0);
    return 0;
}
