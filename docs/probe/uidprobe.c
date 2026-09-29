#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libproc.h>
#include <sys/sysctl.h>
#include <sys/resource.h>
#include <pwd.h>
int main(void){
 int m[4]={CTL_KERN,KERN_PROC,KERN_PROC_ALL,0};size_t l=0;
 if(sysctl(m,4,NULL,&l,NULL,0))return 1;
 struct kinfo_proc*k=malloc(l);if(sysctl(m,4,k,&l,NULL,0))return 1;
 int n=l/sizeof(struct kinfo_proc);uid_t me=getuid();
 int okSame=0,denySame=0,okOther=0,denyOther=0;
 for(int i=0;i<n;i++){pid_t p=k[i].kp_proc.p_pid;if(p<=0)continue;
  uid_t u=k[i].kp_eproc.e_ucred.cr_uid;
  struct rusage_info_v6 ri;memset(&ri,0,sizeof ri);
  int r=proc_pid_rusage(p,RUSAGE_INFO_V6,(rusage_info_t*)&ri);
  int same=(u==me);
  if(r==0){ if(same)okSame++; else okOther++; } else { if(same)denySame++; else denyOther++; }}
 printf("当前 uid = %d\n",me);
 printf("  同 uid  成功 = %d , 同 uid  被拒 = %d\n",okSame,denySame);
 printf("  异 uid  成功 = %d , 异 uid  被拒 = %d\n",okOther,denyOther);
 printf("\n结论: 拒绝是否严格等价于「非当前用户」? %s\n",
        (denySame==0 && okOther==0) ? "是（权限边界 = 用户归属）" : "否（另有其他限制，需进一步确认）");
 return 0;}
