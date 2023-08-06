---
title: "dotfile manager の chezmoi に移行してみる"
featured_image: ""
date: 2023-01-22T12:00:00+09:00
draft: false
slug: '25a8f07bc0e3913807cdf2c3fd48b3cc'
categories: [ "dotfiles" ]
tags: [ "dotfiles" ]
---

[chezmoi](https://www.chezmoi.io/) を使って、 [dotfiles](https://github.com/yoshihisa-ya/dotfiles) を管理することにしました。

dotfiles の管理方法は人それぞれだと思いますが、私は GitHub のパブリックリポジトリでホストしており、 シンボリックリンクを張る Makefile を作成していました。
利用するツールがほぼ統一されていたので、最も利用している環境のみで dotfiles を commit し、他の環境では clone/pull のみ実施し、必要があれば環境固有のファイルを source する運用です。
```
if [ -f ~/.bashrc_private ]; then
    . ~/.bashrc_private # GitHub でホストされていない設定ファイルであり、各マシンで内容は異なる。
fi
```
Makefile では、パッケージマネージャを用いたパッケージのインストールなども行っていましたが、特定ディストリビューションかつネイティブ Linux 環境に特化しているという問題が有りました。
このような雑運用では当然ながら複数環境への対応に脆く、諸事情によりネイティブ Linux から WSL に移行しなければならない環境が発生した際に大量に差分が発生し破綻しました。
気力でメンテナンスを頑張ったり、 WSL や不自由なソフトウェアへの理解を深めたりすれば継続できたかもしれませんが、今後もディストリビューション追加対応などが発生する可能性を鑑み、これを機にテンプレート機能を持つ dotfile manager に移行することにしました。

触れ初めたばかりで、最も利用している環境でしか利用していませんので、テンプレート機能はまだ利用していません。
他に、暗号化やパスワードマネージャとの連携もまだ試していませんので、それらの利用方法も記載しませんのでご了承ください。

<!--more-->

## chezmoi を選んだ理由

chezmoi の[ドキュメント](https://www.chezmoi.io/comparison-table/)に比較表が有りますが、 chezmoi を選んだ主な理由は下記の通りです。

- golang 製シングルバイナリであり、一般ユーザ権限しか与えられていない環境でも容易に動作し、動作OSも多かった。
- 充実したとても良い[ドキュメント](https://www.chezmoi.io/)が存在した。これは同時に、できる事がすぐに把握できた。
- [パスワードマネージャ](https://www.chezmoi.io/user-guide/password-managers/)や[暗号化ツール](https://www.chezmoi.io/user-guide/encryption/)との連携が存在し、かつ、利用している [pass](https://www.passwordstore.org/) が対応していた。
- [テンプレート機能](https://www.chezmoi.io/user-guide/templating/)はもちろんのこと、マシンごとの差分を表現するための十分な手法が存在した。

何よりも大きかったのは、ドキュメントです。
充実していることに加え、 DeepL翻訳 などの翻訳サービスを用いた際に読み易い翻訳結果が出たことも、挫折せずに継続できた理由です。(個人ブログなどは、 DeepL でも、読みにくい翻訳結果となることがたまに有ります...)

## Migration to chezmoi from Makefile

snap などのユニバーサルパッケージも用意されていますが、 Arch Linux ではパッケージマネージャで chezmoi パッケージを導入することもできます。
[`curl | sh` 方式](https://www.chezmoi.io/install/#one-line-binary-install)によるインストールも可能です。

インストールしたら [Quick start](https://www.chezmoi.io/quick-start/) に従い、まずは `chezmoi init` します。

```bash
yoshihisa% chezmoi init
```

これは、 `~/.local/share/chezmoi` に git repository を作成します。
chezmoi は大雑把に言えば、この git repository に各種 dotfiles を、命名規則を用いて保存します。
例えば、 `~/.bashrc` は `dot_bashrc` といった具合です。

```bash
yoshihisa% ls -l ~/.local/share/chezmoi
合計 0
yoshihisa% cd !$
cd ~/.local/share/chezmoi
yoshihisa% git status --branch
On branch master

No commits yet

nothing to commit (create/copy files and use "git add" to track)
```

上記では直接 cd していますが、原則として chezmoi の git repository を扱う場合は cd サブコマンドを用います。
cd サブコマンドを用いると、新しくシェルが起動するので、最後には exit しておきます。

```bash
yoshihisa% chezmoi cd
yoshihisa% # git commit/push など...
yoshihisa% exit
```

dotfiles を chezmoi の管理下とするには、 add サブコマンドを用います。
```bash
yoshihisa% cd
yoshihisa% chezmoi add .bashrc
```

ただし、対象ファイルが symlink である場合は symlink を辿るように `--follow` オプションを用いる必要があります。
さもなければ、 symlink であるという状態が chezmoi によって管理されることなります。
私がこれまで運用していた Makefile 方式や、多くの dotfile manager がシンボリックリンク方式かと思います。

例えば、下記のように追加していきます。

```bash
yoshihisa% chezmoi add --follow .bash_profile
yoshihisa% chezmoi add --follow .bashrc
yoshihisa% chezmoi add --follow .gitconfig
yoshihisa% chezmoi add --follow .tmux.conf
yoshihisa% chezmoi add --follow .vimrc
yoshihisa% chezmoi add --follow .xbindkeysrc
yoshihisa% chezmoi add --follow .xinitrc
yoshihisa% chezmoi add --follow .xscreensaver
yoshihisa% chezmoi add --follow .zprofile
yoshihisa% chezmoi add --follow .zshrc
yoshihisa% chezmoi add --follow .Xmodmap
yoshihisa% chezmoi add --follow .Xresources
yoshihisa% chezmoi add --follow .inputrc
yoshihisa% chezmoi add --follow .config/nvim/init.vim
yoshihisa% chezmoi add --follow .config/picom.conf
yoshihisa% chezmoi add --follow .config/zeno/config.yml
yoshihisa% chezmoi add --follow .config/rofi/config.rasi
```

もう1つ chezmoi で重要なことは、前述の symlink 方式と違い、 chezmoi が管理する git repository (~/.local/share/chezmoi) から対象ファイルが複製されることです。
git repository の内容を適用するためには `chezmoi apply` を実行しますが、

```bash
yoshihisa% chezmoi apply
yoshihisa% ls -li ~/.bashrc ~/.local/share/chezmoi/dot_bashrc
14470350 -rw-r--r-- 1 yoshihisa yoshihisa 2946 12月 18 21:12 /home/yoshihisa/.bashrc
14470345 -rw-r--r-- 1 yoshihisa yoshihisa 2946 12月 18 21:12 /home/yoshihisa/.local/share/chezmoi/dot_bashrc
yoshihisa% md5sum !!2*
md5sum ~/.bashrc ~/.local/share/chezmoi/dot_bashrc
55738b7d4c1b1548bcc41281105e61e5  /home/yoshihisa/.bashrc
55738b7d4c1b1548bcc41281105e61e5  /home/yoshihisa/.local/share/chezmoi/dot_bashrc
```

上記の例では `~/.bashrc` が、シンボリックリンクから、 `~/.local/share/chezmoi/dot_bashrc` の複製となっています。
今回は取り上げませんが、 chezmoi のテンプレート機能を用いた場合、テンプレート処理された内容で `~/.bashrc` が置き換えられます。

おおよそ想像つくかもしれませんが、 chezmoi では、 git repository で編集した後に apply サブコマンドで適用する方式で dotfiles を編集します。
編集は、 git repository 上のファイルを編集するか、 edit サブコマンドを用います。
例えば、 ~/.vimrc(つまり ~/.local/share/chezmoi/dot\_vimrc) を編集し、 diff を確認した後、 ~/.vimrc に適用するには次のステップを踏みます。

```bash
yoshihisa% chezmoi edit ~/.vimrc
yoshihisa% chezmoi diff
yoshihisa% chezmoi apply
```

最後に、 GitHub に dotfiles という名前でリポジトリをホストしておくと、他のホストからも簡単に扱えるので便利です。
下記の通りインストールスクリプトと組み合わせると、 chezmoi のインストールを実施した後、 $GITHUB\_USERNAME の dotfiles リポジトリを clone し、 `chezmoi apply` までワンライナーで実行できます。

```sh
sh -c "$(curl -fsLS get.chezmoi.io)" -- init --apply $GITHUB_USERNAME
```

もし、 GitHub のリモートリポジトリに変更が生じた場合、 update サブコマンドを用いると、リモートリポジトリから pull し apply するまで全て実行されます。

```bash
yoshihisa% chezmoi update
Already up to date.
```

## .chezmoiexternal.toml
[.chezmoiexternal.toml](https://www.chezmoi.io/user-guide/include-files-from-elsewhere/) ファイルを記載することで、外部ファイルを設置することができます。
この機能は、 [Oh My Zsh](https://github.com/ohmyzsh/ohmyzsh) などの設定フレームワークを用いている場合や、 [vim-plug](https://github.com/junegunn/vim-plug) などのプラグインマネージャーを用いている場合に役立ちます。

私は [Neovim](https://neovim.io/) でプラグインマネージャーとして [vim-plug](https://github.com/junegunn/vim-plug) を用いていますが、当然ながら vim-plug 本体を autoload ディレクトリに設置する必要があります。
下記のように .chezmoiexternal.toml を記載すると、 chezmoi apply で自動的に処理してくれます。
dotfiles は凝ってくると、このような関連するファイルの扱いが増えていくので、とても便利な機能です。

```toml
[".local/share/nvim/site/autoload/plug.vim"]
  type = "file"
  url = "https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim"
  refreshPeriod = "168h"
```

vim-plug は単一ファイルでしたが、アーカイブから特定ファイルを展開することも可能です。
下記の例では fuzzy finder である [fzf](https://github.com/junegunn/fzf) を、 GitHub の Latest Release から取得して .local/bin/fzf として設置する例です。

```toml
[".local/bin/fzf"]
  type = "file"
  url = "https://github.com/junegunn/fzf/releases/download/{{ (gitHubLatestRelease "junegunn/fzf").TagName }}/fzf-{{ (gitHubLatestRelease "junegunn/fzf").TagName }}-{{ .chezmoi.os }}_{{ .chezmoi.arch }}.tar.gz"
  executable = true
  refreshPeriod = "168h"
  [".local/bin/fzf".filter]
    command = "tar"
    args = ["--extract", "--file", "/dev/stdin", "--gzip", "--to-stdout", "fzf"]
```

同様に、 [ripgrep](https://github.com/BurntSushi/ripgrep) も下記のように記載することができます。
fzf の例で用いた `{{ .chezmoi.os }}` や `{{ .chezmoi.arch }}` を用いておらず、 x86-64 Linux 決め付けの記述となっている点は手抜きです。
```toml
[".local/bin/rg"]
  type = "file"
  url = "https://github.com/BurntSushi/ripgrep/releases/download/{{ (gitHubLatestRelease "BurntSushi/ripgrep").TagName }}/ripgrep-{{ (gitHubLatestRelease "BurntSushi/ripgrep").TagName }}-x86_64-unknown-linux-musl.tar.gz"
  executable = true
  [".local/bin/rg" .filter]
    command = "tar"
    args = ["--extract", "--file", "/dev/stdin", "--gzip", "--to-stdout", "ripgrep-{{ (gitHubLatestRelease "BurntSushi/ripgrep").TagName }}-x86_64-unknown-linux-musl/rg"]

[".local/share/zsh-completions/_rg"]
  type = "file"
  url = "https://github.com/BurntSushi/ripgrep/releases/download/{{ (gitHubLatestRelease "BurntSushi/ripgrep").TagName }}/ripgrep-{{ (gitHubLatestRelease "BurntSushi/ripgrep").TagName }}-x86_64-unknown-linux-musl.tar.gz"
  [".local/share/zsh-completions/_rg" .filter]
    command = "tar"
    args = ["--extract", "--file", "/dev/stdin", "--gzip", "--to-stdout", "ripgrep-{{ (gitHubLatestRelease "BurntSushi/ripgrep").TagName }}-x86_64-unknown-linux-musl/complete/_rg"]
```

極端な例としては、 AppImage として配布されている Neovim も同様に記載することができます。
```toml
[".local/bin/nvim"]
  type = "file"
  url = "https://github.com/neovim/neovim/releases/latest/download/nvim.appimage"
  executable = true
```

その他にも、ターミナルで [Powerline](https://github.com/powerline/powerline), [lsd](https://github.com/Peltoche/lsd), [exa](https://github.com/ogham/exa) などを使う人は、[Nerd Fonts](https://www.nerdfonts.com/) などのアイコン付きフォントを管理しても便利かもしれません。

## scripts
chezmoi には[任意のスクリプトを実行する機能](https://www.chezmoi.io/user-guide/use-scripts-to-perform-actions/)があります。
例えば、シェルスクリプトを設置し、 `sudo apt install unzip` を実行させることも可能です。
しかし、 sudo 権限が与えられた共用サーバなどで実行してしまう危険性も有るので、 sudo を使わない範囲に留めておくのが良いかと思います。

私の利用例ですが、 Vim プラグインのインストールに用いています。
さきほど AppImage で Neovim をインストールする例や、 プラグインマネージャを .chezmoiexternal.toml を用いて設置する例を記載しました。
このままですと、ログインした後に Neovim を起動し、プライグインマネージャを用いて大量のプラグインをインストールする必要が有ります。
そこで、 run\_once\_after\_neovim-init.sh として下記のシェルスクリプトを設置しておきます。

```bash
#!/bin/bash

~/.local/bin/nvim +PlugInstall +qall
```

これで、新規ホストでも
```sh
sh -c "$(curl -fsLS get.chezmoi.io)" -- init --apply $GITHUB_USERNAME
```
を実行したら、 Neovim がプラグインインストール含めて準備完了した状態となります。
