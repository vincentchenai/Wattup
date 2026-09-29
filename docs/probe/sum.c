#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <libproc.h>
#include <sys/sysctl.h>
#include <sys/resource.h>
#define MAXP 1500
typedef struct { pid_t pid; uint64_t enj, penj, billed, serviced; } r_t;
static int collect(r_t *o){int m[4]={CTL_KERN,KERN_PROC,KERN_PROC_ALL,0};size_t l=0;
 if(sysctl(m,4,NULL,&l,NULL,0))return 0;struct kinfo_proc*k=malloc(l);
 if(sysctl(m,4,k,&l,NULL,0)){free(k);return 0;}int n=l/sizeof(struct kinfo_proc),c=0;
 for(int i=0;i<n&&c<MAXP;i++){pid_t p=k[i].kp_proc.p_pid;if(p<=0)continue;
  struct rusage_info_v6 ri;memset(&ri,0,sizeof ri);
  if(proc_pid_rusage(p,RUSAGE_INFO_V6,(rusage_info_t*)&ri))continue;
  o[c].pid=p;o[c].enj=ri.ri_energy_nj;o[c].penj=ri.ri_penergy_nj;
  o[c].billed=ri.ri_billed_energy;o[c].serviced=ri.ri_serviced_energy;c++;}
 free(k);return c;}
int main(int ac,char**av){int s=ac>1?atoi(av[1]):5;r_t a[MAXP],b[MAXP];
 int na=collect(a);printf("waiting %ds, n=%d\n\n",s,na);sleep(s);int nb=collect(b);
 double te=0,tp=0,tb=0,ts=0;int c=0;
 for(int i=0;i<nb;i++)for(int j=0;j<na;j++)if(a[j].pid==b[i].pid){
   if(b[i].enj>a[j].enj){te+=(b[i].enj-a[j].enj);tb+=(double)(b[i].billed-a[j].billed);ts+=(double)(b[i].serviced-a[j].serviced);c++;}
   if(b[i].penj>a[j].penj)tp+=(b[i].penj-a[j].penj);
   break;}
 printf("有增量进程数        = %d\n",c);
 printf("Σ ri_energy_nj      = %.3e nJ = %.3f J -> %.1f mW\n",te,te/1e9,te/(1e6*s));
 printf("Σ ri_penergy_nj     = %.3e nJ = %.3f J -> %.1f mW\n",tp,tp/1e9,tp/(1e6*s));
 printf("Σ ri_billed_energy  = %.3e     = %.3f J -> %.1f mW\n",tb,tb/1e9,tb/(1e6*s));
 printf("Σ ri_serviced_energy= %.3e     = %.3f J -> %.1f mW\n",ts,ts/1e9,ts/(1e6*s));
 return 0;}
