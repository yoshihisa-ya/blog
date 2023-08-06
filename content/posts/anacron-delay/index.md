---
title: "anacron の実行タイミング"
featured_image: ""
date: 2021-11-23T16:30:00+09:00
draft: false
slug: '12f36510764a7028c875b217720ac481'
categories: [ "code" ]
tags: [ "code", "linux" ]
---

本記事は、CentOS 8のリリース時に調査した内容を、Rocky Linux 8.5 ベースで再調査した内容です。

仮想マシンの普及に合わせて、実行タイミングをランダム化しホストサーバに負荷が集中しないようにできる anacron は注目されたタスクスケジューラーですが、設定ファイルの内容とジョブの実行タイミングについて、誤った認識を持つ事が有ります。
例えば、以下の `/etc/anacrontab` において、ジョブが実行されるのは次のどれでしょうか？

```
]$ cat /etc/anacrontab
# /etc/anacrontab: configuration file for anacron

# See anacron(8) and anacrontab(5) for details.

SHELL=/bin/sh
PATH=/sbin:/bin:/usr/sbin:/usr/bin
MAILTO=root
# the maximal random delay added to the base delay of the jobs
RANDOM_DELAY=45
# the jobs will be started during the following hours only
START_HOURS_RANGE=3-22

#period in days   delay in minutes   job-identifier   command
1       5       cron.daily              nice run-parts /etc/cron.daily
7       25      cron.weekly             nice run-parts /etc/cron.weekly
@monthly 45     cron.monthly            nice run-parts /etc/cron.monthly
```

A. START_HOURS_RANGE と RANDOM_DELAY から求められ、[3-22]:00 - [3-22]:45 のいずれかランダム。つまり、3時 ~ 23時 の間の 00分 ~ 45分 のいずれか。  
B. 上記のAに `delay in minutes` を足した値。cron.dailyであれば 5 なので、 [3-22]:05 - [3-22]:50 のいずれかランダム。  
C. 上記のBの範囲にて、 anacron が最も初めに起動したタイミング。つまり24h稼動であれば 3:[05-50] のいずれかランダムに実施し、3:51以降に cron.daily を実施する事は無い。22:00 にマシンが初めて起動した場合、 22:[05-50] のいずれかランダム。  
D. 上記のCと似ているが、「`delay in minutes` + (RANDOM_DELAYによってランダムに算出された分数)」は、毎時00分では無く、 anacron の起動タイミングに加算される。つまり、 21:58 に anacron が初めて起動し RANDOM_DELAY で算出された値が3で有る場合に cron.daily であれば 「21:58 + 5 + 3 = 22:06」 に実行される。START_HOURS_RANGE の範囲外である 22:01 にanacronが起動した場合は範囲外なので実行されない。  
E. 上記のDと似ているが、ジョブ実行タイミングが START_HOURS_RANGE の範囲内である場合のみ実行する。つまり、 21:52 に anacron が初めて起動し RANDOM_DELAY で算出された値が3で有る場合に cron.daily であれば 「21:52 + 5 + 3 = 22:00」 に実行される。より厳密には、22:00:00 は範囲内として実行されるが、22:00:01 以降であれば、実行しない。
<!--more-->

これらは全て誤りです。Eは正解に近いのですが、コードを見ると厳密には誤りである事が分かります。
また、 RANDOM_DELAY によって求められる値はジョブ「cron.daily, cron.weekly, cron.monthly」 ごとに異なるのか同一なのか、そのような疑問も出てきます。
Rocky Linux 8.5 を用いて説明を記載していきます。

## 検証環境
Rocky Linux 8.5 (minimal install)
```
]$ cat /etc/rocky-release
Rocky Linux release 8.5 (Green Obsidian)
]$ rpm -qa | grep cron
crontabs-1.11-17.20190603git.el8.noarch
cronie-anacron-1.5.2-4.el8.x86_64
cronie-1.5.2-4.el8.x86_64
```

## anacron 実行のしくみ
anacron はデーモンとして動作しません。
cron の設定ファイルを確認すると、デーモンとして動作している cron が anacron を呼び起こしている事が分かります。

`/etc/cron.d` には 0hourly ファイルのみが存在し、中身を確認すると、毎時1分に /etc/cron.hourly ディレクトリ内のファイルに記載された内容を実行する記載が有ります。

なお、 run-parts もコマンドであり、Debian系はバイナリ実装/RHEL系はシェルスクリプト実装である事、受けとる引数や無視するファイル名規則が異なる事も注意が必要です。run-parts について、本記事ではこれ以上扱いません。
```
]$ ls -l /etc/cron.d
合計 4
-rw-r--r--. 1 root root 128  3月 15  2021 0hourly
]$ cat /etc/cron.d/0hourly
# Run the hourly jobs
SHELL=/bin/bash
PATH=/sbin:/bin:/usr/sbin:/usr/bin
MAILTO=root
01 * * * * root run-parts /etc/cron.hourly
```

`/etc/cron.hourly` には 0anacron ファイルのみ存在し、必要に応じて anacron を起動するようになっています。
この 0anacron を読んでみると、
1. `/var/spool/anacron/cron.daily` ファイルに今日の日付が書き込まれているか確認し、記載されていれば終了する。
2. システムがバッテリー駆動か確認し、バッテリー駆動であれば終了する。
3. `/usr/sbin/anacron -s` を実行する。

となっており、当日中は1回のみ起動する制御と、バッテリー駆動での起動を行わないようになっています。
```
]$ ls -l /etc/cron.hourly/
合計 4
-rwxr-xr-x. 1 root root 575  3月 15  2021 0anacron
]$ cat /etc/cron.hourly/0anacron
#!/bin/sh
# Check whether 0anacron was run today already
if test -r /var/spool/anacron/cron.daily; then
    day=`cat /var/spool/anacron/cron.daily`
fi
if [ `date +%Y%m%d` = "$day" ]; then
    exit 0
fi

# Do not run jobs when on battery power
online=1
for psupply in AC ADP0 ; do
    sysfile="/sys/class/power_supply/$psupply/online"

    if [ -f $sysfile ] ; then
        if [ `cat $sysfile 2>/dev/null`x = 1x ]; then
            online=1
            break
        else
            online=0
        fi
    fi
done
if [ $online = 0 ]; then
    exit 0
fi
/usr/sbin/anacron -s
```

今更ですが、ここで `man 8 anacron` の冒頭 DESCRIPTION を読んでみると次のような内容が記載されています。

1. 日単位で指定された頻度で定期的にコマンドを実行するために利用できる。
2. マシンが継続的に稼働していることを前提としておらず、24時間稼働していないマシンでも定期的なジョブを実行できる。
3. /etc/anacrontab からジョブリストを読み込む。
4. 各ジョブについて、過去n日間に実行されたかどうかをチェックし、実行されていない場合実行する。
5. ジョブが終了した後、そのジョブ用のタイムスタンプファイルに日付を書き込む。(先に記載したファイル)
6. 実行するジョブが無くなると終了する。

ここで気にしておくべき点として、 anacron は24時間稼動していないマシンでも定期ジョブを実行できる機構であるという事です。
24h稼動のVMを前提にすると、指定時間内でのランダム遅延という特性を重視しがちですが、マニュアルの DESCRIPTION では、ランダム遅延に関する記載は有りません。
プログラムが解決する本題を誤って解釈したまま設定ファイルを読み取ると、説明コメントを異なる意味に解釈する事が有るので、これは注意すべき点です。

上記の前提を元に、設定ファイル /etc/anacrontab のマニュアル `man 5 anacrontab` を読んでみると次のような内容が記載されています。

/etc/anacrontab 抜粋
```
RANDOM_DELAY=45
START_HOURS_RANGE=3-22

#period in days   delay in minutes   job-identifier   command
1       5       cron.daily              nice run-parts /etc/cron.daily
7       25      cron.weekly             nice run-parts /etc/cron.weekly
@monthly 45     cron.monthly            nice run-parts /etc/cron.monthly
```

1. ジョブ記述行は `period-in-days delay-in-minutes job-identifier command` のフォーマットである。
2. period-in-days は、ジョブの実行頻度を日単位で示し、整数の他に @daily, @weekly, @monthly を用いる事ができる。
3. delay-in-minutes は、ジョブを実行する前にwaitする分数を指定できる。0だと遅延無く実施される。
4. job-identifier は、ログファイルで利用する識別子であり、ユニークである必要が有る。

環境変数について、 RANDOM_DELAY と START_HOURS_RANGE は次の通りの記載が有ります。

5. START_HOURS_RANGE は、スケジュールされたジョブを実行することができるインターバルを示す。パワーダウン等によりこの範囲に無い時は実行されない。
6. RANDOM_DELAY は、ジョブに指定されている delay-in-minutes に追加される最大分数である。12を指定した場合、0 ~ 12のいずれかが delay-in-minutes に加算される。

ここまでで、 cron.daily であれば分(minute)の部分は、`delay-in-minutes + RANDOM_DELAY(による算出値)` で、その値は 5 ~ 50 のいずれかとなる事が分かります。
anacron が起動した後、この値だけwaitして実行する事となります。

実行できる時(hour)を示す START_HOURS_RANGE の 3-22 は、ドキュメント通りの解釈をすれば、「スケジュールされたジョブ」ですから、上記のwaitした後の実際に実行される時刻が 3:00 ~ 22:00 であれば実行するように解釈できます。

ドキュメントから読み解けた内容を改めて整理します。
1. 24時間稼動していないマシンでも定期ジョブを実行できる機構である。
2. anacronが起動した後に、 `delay-in-minutes + RANDOM_DELAY(による算出値)` だけwaitしてジョブを実行する。毎時00分基準のA, B, Cは不正解。
3. 実際にwaitしジョブを実行するタイミングが START_HOURS_RANGE 内に無ければならない。 anacron の起動タイミングが START_HOURS_RANGE 内で有れば良いとした A, B, C, Dは不正解。

なお、上記の 3 も、厳密には正しくありません。これは最後に記述します。

## ソースコードを確認する
ドキュメントに記載の内容が正しいかソースコードを確認します。
ドキュメントの内容を誤って解釈(英語ネイティブで無いので尚更)していたり、そもそもドキュメントが誤っている事(完全な誤り or 古いなど)は多く有るので、確認するのが安全です。

加えて、次の内容も確認します。
1. RANDOM_DELAY によって算出される値は、各ジョブ(cron.daily, cron.weekly, cron.monthly)で統一なのか別々なのか。
2. START_HOURS_RANGE で設定するインターバルの終わりは、厳密にどの時点なのか。3-22であれば、 22:00:00 が対象で 22:00:01 が対象外なのか、もしくは 22:00:59 まで対象なのか、いずれも不正解なのか。

用いるコードは次の通りです。
```
]$ yumdownloader --source cronie-anacron
]$ rpm -ivh cronie-1.5.2-4.el8.src.rpm
]$ rpmbuild -bp ~/rpmbuild/SPECS/cronie.spec
]$ cd ~/rpmbuild/BUILD/cronie-1.5.2
```
コードは下記から閲覧できるようにしてあります。
必要に応じてご確認ください。

https://ftp.yamano.dev/blog/htags/cronie-1.5.2-4.el8.src.rpm/

anacron の main.c から重要な箇所を抜粋し、コメントを記載しています。

[anacon/main.c parse_opts()](https://ftp.yamano.dev/blog/htags/cronie-1.5.2-4.el8.src.rpm/S/23.html#L101)
```
100 static void
101 parse_opts(int argc, char *argv[])
102 /* Parse command-line options */
103 {
104     int opt;
105
106     quiet = no_daemon = serialize = force = update_only = now = 0;
107     opterr = 0;
108     while ((opt = getopt(argc, argv, "sfundqt:TS:Vh")) != EOF)
109     {
110         switch (opt)
111         {
112         case 's':
113             serialize = 1;
114             break;

```

[anacon/main.c main()](https://ftp.yamano.dev/blog/htags/cronie-1.5.2-4.el8.src.rpm/S/23.html#L435)
```
457     parse_opts(argc, argv);

483     record_start_time(); /* anacron が開始した時刻を記録 */
484     read_tab(cwd);       /* /etc/anacrontab を読む */
485     close(cwd);
486     arrange_jobs();      /* ジョブを実行順にソートし配列とする */

503     running_jobs = running_mailers = 0;
504     for(j = 0; j < njobs; ++j) /* ソートされたジョブを順次実行する */
505     {
506         xsleep(time_till(job_array[j])); /* ジョブの開始時間までsleepする */
507         if (serialize) wait_jobs();      /* if true なら、実行中のジョブが有れば終了まで待機する。 */
508         launch_job(job_array[j]);        /* ジョブをforkする。ここでは子が終了するのを待たない。 */
509     }
```

/etc/anacrontab に記載している内容を読み実行順にソートした後、開始時刻まで待ちforkする事を繰り返しています。
今回の場合は、 `-s` オプションで起動されている為、L507によりジョブが並列で実行される事は有りません。

確認すべき内容が read_tab(), arrange_jobs() に有るので詳しく見ていきます。

[anacon/readtab.c read_tab()](https://ftp.yamano.dev/blog/htags/cronie-1.5.2-4.el8.src.rpm/S/28.html#L384)
```
383 void
384 read_tab(int cwd)
385 /* Read the anacrontab file into memory */
386 {
387     char *tab_line;

392     line_num = 0;

402     while ((tab_line = read_tab_line()) != NULL) /* 最終行まで1行ずつ /etc/anacrontab を読む */
403     {
404         line_num++;                       /* 読んだ行数 */
405         parse_tab_line(tab_line);         /* 1行パースする */
406         obstack_free(&input_o, tab_line);
407     }
408     if (fclose(tab)) die_e("Error closing %s", anacrontab);
409 }
```

重要な部分は parse_tab_line() に有るので更に追います。

[anacon/readtab.c parse_tab_line()](https://ftp.yamano.dev/blog/htags/cronie-1.5.2-4.el8.src.rpm/S/28.html#L84)
```
            /* START_HOURS_RANGE 定義のパース */
315         if (strncmp(env_var, "START_HOURS_RANGE", 17) == 0)
316         {
                /* 3-22なら、range_start=3, range_stop=22 とする */
317             r = match_rx("^([[:digit:]]+)-([[:digit:]]+)$", value, 2, &from, &to);

320             range_start = atoi(from);
321             range_stop = atoi(to);

                /* ex.ジョブの開始時刻は、03:00-22:00の範囲内となります。 */
326             Debug(("Jobs will start in the %02d:00-%02d:00 range.", range_start, range_stop));

            /* RANDOM_DELAY 定義のパース */
328         else if (strncmp(env_var, "RANDOM_DELAY", 12) == 0) {
329             r = match_rx("^([[:digit:]]+)$", value, 0);

                /* ランダムの結果を random_number とする。 */
333             random_number = (int)unbiased_rand(atoi(value));

        /* ジョブのパース */
353     r = match_rx("^[ \t]*([[:digit:]]+)[ \t]+([[:digit:]]+)[ \t]+"
354                  "([^ \t/]+)[ \t]+([^ \t].*)$",
355                  line, 4, &periods, &delays, &ident, &command);

            /* ジョブを登録する */
359         register_job(periods, delays, ident, command);
```

RANDOM_DELAY によって1つの値 random_number が決定しました。
cron.daily 等の各ジョブ毎に異なる値を算出はしていないので、全てのジョブで同一の時間を用いる事になります。
前述の通り、「`delay-in-minutes + RANDOM_DELAY(による算出値)` だけwaitしてジョブを実行」する為、各ジョブのdelay-in-minutesは、実行順序を決定する要素となります。
今回の例では、cron.daily=5, cron.weekly=25, cron.monthly=45 となっているので、全てが実行可能である場合、daily, weekly, monthlyの順番にシーケンシャル実行されます。

anacrontab がメモリ上にロードされました。
引き続き、main() に戻り、arrange_jobs()を追う事にします。

[anacon/readtab.c arrange_jobs()](https://ftp.yamano.dev/blog/htags/cronie-1.5.2-4.el8.src.rpm/S/28.html#L427)
```
435     j = first_job_rec;
436     njobs = 0;
437     while (j != NULL)
438     {
            /* consider_job()が呼ばれる。 */
439         if (j->arg_num != -1 && (update_only || testing_only || consider_job(j)))
440         {
441             njobs++;
442             obstack_grow(&tab_o, &j, sizeof(j));
443         }
444         j = j->next;
445     }
446     job_array = obstack_finish(&tab_o);
447
448     /* sort the jobs */
449     qsort(job_array, (size_t)njobs, sizeof(*job_array),
450           (int (*)(const void *, const void *))execution_order);
```

L449 で、実行順にソートしています。
その前に、L439 で consider_job() が呼ばれており、これを追ってみます。

[anacon/lock.c consider_job()](https://ftp.yamano.dev/blog/htags/cronie-1.5.2-4.el8.src.rpm/S/21.html#L77)
```
 97         time_t jobtime;
 98         struct tm *t;

            /* ジョブの開始時刻を求め jobtime(unixtime) とする。 */
            /* anacron起動時刻 + (delay-in-minutes + random_number) * 60 */
156         jobtime = start_sec + jr->delay * 60;
157
158         t = localtime(&jobtime);

            /* ジョブ実行時間の時(hour)が指定時間内に無ければスキップ。 */
165         if (!now && range_start != -1 && range_stop != -1 &&
166                 (t->tm_hour < range_start || t->tm_hour >= range_stop))
167         {
168                 Debug(("The job `%s' falls out of the %02d:00-%02d:00 hours range, skipping.",
169                         jr->ident, range_start, range_stop));
170                 xclose (jr->timestamp_fd);
171                 return 0;
172         }
```
重要なのは、L165のifです。
now は -n(nodelay) オプションで true となります。
今回は -n オプションを用いていないので、START_HOURS_RANGE 内にジョブが実行開始されるか確認しています。
この時、range_stop=22 なので、ジョブは 21:59:59 開始までであれば実行され、 22:00:00 開始であればスキップされます。

22:00:00 にスケジュールされたジョブは実行されませんので、Eは不正解となります。


## gdbでソースコードを追跡する
anacron が参照する記録ファイル cron.daily を下記の通り前日に変更のうえ、gdbでソースコードを追跡します。
monthlyとweeklyは空ファイルにしています。
```
]# date
Sat Nov 20 19:10:02 JST 2021
]# ls -l /var/spool/anacron/cron.*
-rw-------. 1 root root 9 Nov 20 19:09 /var/spool/anacron/cron.daily
-rw-------. 1 root root 0 Nov 20 18:53 /var/spool/anacron/cron.monthly
-rw-------. 1 root root 0 Nov 20 18:53 /var/spool/anacron/cron.weekly
]# cat /var/spool/anacron/cron.daily
20211119
```

anacron は、 -d オプションを付け、forkしない形で実行します。
[anacon/lock.c consider_job()](https://ftp.yamano.dev/blog/htags/cronie-1.5.2-4.el8.src.rpm/S/21.html#L77) に break point を張り、まずは cron.daily から処理が行われる事を確認します。
```
]# gdb --args /usr/sbin/anacron -sd
(gdb) b consider_job
Breakpoint 1 at 0x3390: file lock.c, line 81.
(gdb) r
(gdb) p jr->command
$1 = 0x555555765880 "nice run-parts /etc/cron.daily"
(gdb)
```

[L156](https://ftp.yamano.dev/blog/htags/cronie-1.5.2-4.el8.src.rpm/S/21.html#L156) まで進め、start_sec, jr->delay, random_number を確認してみます。
start_sec は anacron が起動した時間(unixtime) が入っており、この例では「2021年11月20日 19:10:38」です。

jr->delay はジョブの遅延時間であり、 delay-in-minutes の 5 に対し、 RANDOM_DELAY により決定した random_number 2 を加算し 7 となっています。
```
(gdb) p start_sec
$6 = 1637403038
(gdb) p jr->delay
$7 = 7
(gdb) p random_number
$8 = 2
(gdb)
```

停止している L156 で実際のジョブ開始時刻を求めているので、更に [L159](https://ftp.yamano.dev/blog/htags/cronie-1.5.2-4.el8.src.rpm/S/21.html#L159) まで進めてみます。
ジョブ開始時刻の jobtime は 「start_sec + jr->delay * 60」で計算された値となり、これを struct tm に変換した t を確認すると、きちんと「2021年11月20日 19:17:38」に開始される事となっています。
(struct tm の tm_mon は 1月=0 であり +1 すべき事、tm_year は 1900 を引かれているため +1900 すべき事に注意してください。)
```
(gdb) p jobtime
$9 = 1637403458
(gdb) p *t
$13 = {
  tm_sec = 38,
  tm_min = 17,
  tm_hour = 19,
  tm_mday = 20,
  tm_mon = 10,
  tm_year = 121,
  tm_wday = 6,
  tm_yday = 323,
  tm_isdst = 0,
  tm_gmtoff = 32400,
  tm_zone = 0x555555763660 "JST"
}
(gdb)
```

/var/spool/anacron/\* を同様にし、gdbを改めて開始させ、今回は境界チェックを実施しようと思います。
START_HOURS_RANGE=3-22 である場合に、22:00:00 にジョブが開始される場合はスキップされる事を確認します。

同様に [anacon/lock.c consider_job()](https://ftp.yamano.dev/blog/htags/cronie-1.5.2-4.el8.src.rpm/S/21.html#L77) に break point を張り、 cron.daily から処理が行われる事を確認します。
```
]# gdb --args /usr/sbin/anacron -sd
(gdb) b consider_job
Breakpoint 1 at 0x3390: file lock.c, line 81.
(gdb) r
(gdb) p jr->command
$1 = 0x555555765880 "nice run-parts /etc/cron.daily"
(gdb)
```

[L158](https://ftp.yamano.dev/blog/htags/cronie-1.5.2-4.el8.src.rpm/S/21.html#L158) まで進め、改めて jobtime を確認すると、「2021年11月20日 20:12:21」 となっています。
この jobtime を改変し、「2021年11月20日 22:00:00」に開始するようにします。
```
(gdb) p jobtime
$2 = 1637406741
(gdb) p jobtime=1637413200
$3 = 1637413200
(gdb) n
(gdb) p *t
$4 = {
  tm_sec = 0,
  tm_min = 0,
  tm_hour = 22,
  tm_mday = 20,
  tm_mon = 10,
  tm_year = 121,
  tm_wday = 6,
  tm_yday = 323,
  tm_isdst = 0,
  tm_gmtoff = 32400,
  tm_zone = 0x555555763660 "JST"
}
(gdb)
```

この状態で進めていくと、下記のように [L165](https://ftp.yamano.dev/blog/htags/cronie-1.5.2-4.el8.src.rpm/S/21.html#L165) の if の内側に入り、ジョブがスキップされる事が分かります。
```
   x165             if (!now && range_start != -1 && range_stop != -1 &&                                          x
   x166                     (t->tm_hour < range_start || t->tm_hour >= range_stop))                               x
   x167             {                                                                                             x
   x168                     Debug(("The job `%s' falls out of the %02d:00-%02d:00 hours range, skipping.",        x
   x169                             jr->ident, range_start, range_stop));                                         x
  >x170                     xclose (jr->timestamp_fd);                                                            x
   x171                     return 0;                                                                             x
   x172             }                                                                                             x
   x173         }                                                                                                 x
   x174
```

プログラムを continue すると、 cron.daily は実行予定されず、cron.weekly と cron.monthly のみが実行待ちとなります。
```
(gdb) c

Will run job `cron.weekly' in 62 min.
Will run job `cron.monthly' in 82 min.
Jobs will be executed sequentially
```

## START_HOURS_RANGE が守られない事例
ソースコードを読んでみると、 START_HOURS_RANGE が守られないと思われる事例が見つかります。
### 日付記録ファイルの記録が8文字に満たない
/var/spool/anacron/ にジョブ名のファイルを作成し実行日を8文字 YYYYMMDD の形式で記録しています。
コードを読むと、[L89](https://ftp.yamano.dev/blog/htags/cronie-1.5.2-4.el8.src.rpm/S/21.html#L89)でファイルを read(2) した戻り値を b としています。
[L94](https://ftp.yamano.dev/blog/htags/cronie-1.5.2-4.el8.src.rpm/S/21.html#L94) の if で b == 8 の場合に指定日数が経過しているか、 START_HOURS_RANGE 内の実行スケジュールかを確認している為、b != 8 の場合は START_HOURS_RANGE が守られません。
なお、9文字以上である場合や、ファイルが存在しない場合は、挙動が異なります。

実際に、次の通り
1. START_HOURS_RANGE を時刻外
1. cron.daily の実行日記録は 4 文字としておく。
1. cron.weekly の実行日記録は 9 文字としておく。
1. cron.monthly は実行日記録のファイルが無い。

に改変し確認してみます。
なお、実験の関係上、直ぐに結果が出るよう、他のRANDOM_DELAY及びdelay-in-minutesも変更してます。

期待するのは、いずれのケースでも START_HOURS_RANGE の範囲外として実行され無い事です。

```
]# date
Tue Nov 23 14:43:06 JST 2021
]# cat /etc/anacrontab
# /etc/anacrontab: configuration file for anacron

# See anacron(8) and anacrontab(5) for details.

SHELL=/bin/sh
PATH=/sbin:/bin:/usr/sbin:/usr/bin
MAILTO=root
# the maximal random delay added to the base delay of the jobs
RANDOM_DELAY=0
# the jobs will be started during the following hours only
START_HOURS_RANGE=3-12

#period in days   delay in minutes   job-identifier   command
1       1       cron.daily              nice run-parts /etc/cron.daily
7       2       cron.weekly             nice run-parts /etc/cron.weekly
@monthly 3      cron.monthly            nice run-parts /etc/cron.monthly
]# ls -l /var/spool/anacron/
total 8
-rw-------. 1 root root  5 Nov 23 14:43 cron.daily
-rw-------. 1 root root 10 Nov 23 14:36 cron.weekly
]# grep . /var/spool/anacron/*
/var/spool/anacron/cron.daily:2021
/var/spool/anacron/cron.weekly:202111011
```

実際に実行してみます。
```
]# date; /usr/sbin/anacron -sd
Tue Nov 23 14:49:09 JST 2021
Anacron started on 2021-11-23
Will run job `cron.daily' in 1 min.
Will run job `cron.monthly' in 3 min.
Jobs will be executed sequentially
Job `cron.daily' started
Job `cron.daily' terminated
Job `cron.monthly' started
Job `cron.monthly' terminated
Normal exit (2 jobs run)
```
START_HOURS_RANGE の範囲外でしたが、 cron.daily と cron.monthly が実行されました。
今回は RANDOM_DELAY を 0 としているので、delay-in-minutesがそのまま遅延時間として用いられスケジュールされています。

cron.weekly は 9文字のファイルを作成していました。
しかし、 read(2) に8文字まで読む指定がされている事から、 202111011 では無く 20211101 として読まれますし、read(2)の戻り値も 8 です。
下記の通り gdb で実行すると、b == 8 及び、20211101 として読んでいる事が分かります。
これは正しい値ですから、先に記載した [L94](https://ftp.yamano.dev/blog/htags/cronie-1.5.2-4.el8.src.rpm/S/21.html#L94) の if に入り、START_HOURS_RANGE の評価が行われ、実行がスキップされた事となります。
9文字以上である場合、先頭8文字のみが用いられ START_HOURS_RANGE の評価が行われ守られる事となります。

```
]# gdb --args /usr/sbin/anacron -sd
(gdb) b lock.c:89
Breakpoint 1 at 0x33d3: file lock.c, line 90.
(gdb) r

// cron.weekly まで進める

(gdb) p jr->command
$5 = 0x555555765920 "nice run-parts /etc/cron.weekly"
(gdb) p b
$6 = 8
(gdb) p timestamp
$7 = "20211101"
(gdb)
```

日付記録ファイルを確認してみると、cron.dailyは正常に更新され、cron.monthlyは作成されています。
```
]# ls -l /var/spool/anacron/
total 12
-rw-------. 1 root root  9 Nov 23 14:50 cron.daily
-rw-------. 1 root root  9 Nov 23 14:52 cron.monthly
-rw-------. 1 root root 10 Nov 23 14:36 cron.weekly
]# grep . /var/spool/anacron/*
/var/spool/anacron/cron.daily:20211123
/var/spool/anacron/cron.monthly:20211123
/var/spool/anacron/cron.weekly:202111011
```

### 前ジョブの実行に時間を要した
forkしジョブを開始した後に、次に実行するジョブの開始時間まで待ちます。
しかし、 -s オプションが有効である(Rocky Linux 標準)場合、次のジョブの開始時間を迎えても、forkした子が終了するまで待つのは前述した通りです。
これは、時間を要し START_HOURS_RANGE 内にジョブが終了しなかった場合、次のジョブは START_HOURS_RANGE 外の時間に実行開始される可能性を示します。


anacron の設定については次の通りとします。
1. START_HOURS_RANGE は時間内
1. 日付記録ファイルは正常、cron.daily, cron.weekly が実行される。

先ほどと同様に、直ぐに結果が出るよう、他のRANDOM_DELAY及びdelay-in-minutesも変更してます。

```
]# date
Tue Nov 23 15:34:47 JST 2021
]# cat /etc/anacrontab
# /etc/anacrontab: configuration file for anacron

# See anacron(8) and anacrontab(5) for details.

SHELL=/bin/sh
PATH=/sbin:/bin:/usr/sbin:/usr/bin
MAILTO=root
# the maximal random delay added to the base delay of the jobs
RANDOM_DELAY=0
# the jobs will be started during the following hours only
START_HOURS_RANGE=3-16

#period in days   delay in minutes   job-identifier   command
1       1       cron.daily              nice run-parts /etc/cron.daily
7       2       cron.weekly             nice run-parts /etc/cron.weekly
@monthly 3      cron.monthly            nice run-parts /etc/cron.monthly
]# ls -l /var/spool/anacron/
total 12
-rw-------. 1 root root 9 Nov 23 15:28 cron.daily
-rw-------. 1 root root 9 Nov 23 15:29 cron.monthly
-rw-------. 1 root root 9 Nov 23 15:29 cron.weekly
]# grep . /var/spool/anacron/*
/var/spool/anacron/cron.daily:20211122
/var/spool/anacron/cron.monthly:20211101
/var/spool/anacron/cron.weekly:20211101
```

/etc/cron.daily に時間のかかるジョブを置いておきます。
```
]# cat /etc/cron.daily/junk.sh
#!/bin/bash

sleep 1800
touch /root/junk.daily
```
30分sleepするスクリプトなので、15:29:00 以降に anacron を起動させれば、続いて実行される cron.weekly は START_HOURS_RANGE 外に実行されるはずです。

続いて実行される /etc/cron.weekly には、瞬時に終了するジョブを置いておきます。
```
]# cat /etc/cron.weekly/junk.sh
#!/bin/bash

touch /root/junk.weekly
```
なお、cron.daily, cron.weekly のどちらも実行対象とする必要が有るので、15:57:59 までに anacron を起動させる必要が有ります。

実際に実行してみます。
```
# date; /usr/sbin/anacron -sd
Tue Nov 23 15:42:06 JST 2021
Anacron started on 2021-11-23
Checking against 22 with 31
Will run job `cron.daily' in 1 min.
Will run job `cron.weekly' in 2 min.
Jobs will be executed sequentially
Job `cron.daily' started
Job `cron.daily' terminated
Job `cron.weekly' started
Job `cron.weekly' terminated
Normal exit (2 jobs run)
```

想定通り、 cron.daily, cron.weekly が実行され終了しました。

`/var/log/cron` を確認するとタイムスタンプ付きで確認できますが、 cron.daily の実行に時間がかかり、 cron.weekly が START_HOURS_RANGE の範囲外に実行開始されています。
```
Nov 23 15:42:06 localhost anacron[9793]: Anacron started on 2021-11-23
Nov 23 15:42:06 localhost anacron[9793]: Will run job `cron.daily' in 1 min.
Nov 23 15:42:06 localhost anacron[9793]: Will run job `cron.weekly' in 2 min.
Nov 23 15:42:06 localhost anacron[9793]: Jobs will be executed sequentially
Nov 23 15:43:06 localhost anacron[9793]: Job `cron.daily' started
Nov 23 16:13:06 localhost anacron[9793]: Job `cron.daily' terminated
Nov 23 16:13:06 localhost anacron[9793]: Job `cron.weekly' started
Nov 23 16:13:06 localhost anacron[9793]: Job `cron.weekly' terminated
Nov 23 16:13:06 localhost anacron[9793]: Normal exit (2 jobs run)
```

スクリプトで作成されたファイルも次の通りです。
```
# ls -l /root/junk.*
-rw-r--r--. 1 root root 0 11月 23 16:13 /root/junk.daily
-rw-r--r--. 1 root root 0 11月 23 16:13 /root/junk.weekly
```

## まとめ
Rocky Linux 8.5 において
1. /etc/cron.hourly/ は crond により毎時1分に実行され、いくつかの条件を満たせば、それにより anacron は起動する。
1. /etc/cron.daily/, /etc/cron.weekly/, /etc/cron.monthly/ は、 anacron が担当する。
1. anacron が起動した時刻に 「delay in minutes + (RANDOM_DELAYによってランダムに算出された分数)」 が加算され、ジョブはスケジュールされる。
1. スケジュールされた時刻が START_HOURS_RANGE の範囲内であれば実行される。3-22である場合、 3:00 - 22:00 であるが、厳密には 時 が 3-21 であれば実行されるため、22:00:00 は範囲内では無い。
1. 実行日が記録されたファイルのフォーマットが不正である場合、 START_HOURS_RANGE の範囲外で有っても実行される事が有る。
1. 標準で -s オプションが設定されており、前ジョブの遅延により、後続のジョブが START_HOURS_RANGE の範囲外に実行される事が有る。
