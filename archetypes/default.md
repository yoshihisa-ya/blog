---
title: "{{ replace .Name "-" " " | title }}"
date: {{ .Date }}
draft: true
slug: '{{ .File.UniqueID  }}'
categories: [ "categories" ]
tags: [ "tags1", "tags2" ]
---

