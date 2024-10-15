#!/bin/sh

mkdir -p output
cp icon.svg output

preamble='<!doctype html>
<html lang=en itemscope itemtype="https://schema.org/SoftwareApplication">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Myba - git-based file backup with encryption</title>
<link rel="logo icon" href="icon.svg">
<meta name="theme-color" content="#333">
<meta itemprop="applicationCategory" content="BusinessApplication"><meta itemprop="applicationCategory" content="DeveloperApplication"><meta itemprop="applicationCategory" content="SecurityApplication"><meta itemprop="applicationCategory" content="UtilitiesApplication">
<meta itemprop="operatingSystem" content="Linux"><meta itemprop="operatingSystem" content="macOS"><meta itemprop="operatingSystem" content="Windows">
<meta itemprop="isAccessibleForFree" content="true">
<meta itemprop="license" content="https://www.gnu.org/licenses/agpl-3.0.txt">
<meta itemprop="sameAs" content="https://github.com/kernc/myba/">
<meta itemprop="url" content="/">
<script async src="https://www.googletagmanager.com/gtag/js?id=G-JT9W3RXCJD"></script>
<script>window.dataLayer=window.dataLayer||[];function gtag(){dataLayer.push(arguments);}gtag("js",new Date());gtag("config","G-JT9W3RXCJD");</script>
<style>
html{background:DarkOliveGreen; line-height: 1.4em; font-family:}
article {background:#fffb; padding:2em; margin:auto; max-width: 900px;}
pre {background:#fff8; padding: 1em;}
code:not(pre code) {background:#fff8; padding: .2em .5em; white-space: nowrap;}
ul li code:not(pre code):first-child {font-weight: bold;}
h1,h2,h3,h4 {margin-top: 2em}
a {color:navy}
</style>
<meta property="og:title" content="Myba - git-based file backup with encryption">
<meta property="og:type" content="website">
<meta property="og:url" content="https://kernc.github.io/myba/">
<meta property="og:image" content="https://kernc.github.io/myba/icon.svg">
</head>
<body><main><article>
'
postamble='</article></main></body></html>'
{
    echo "$preamble"
    python -m markdown -x extra -x toc README.full.md
    echo "$postamble"
} > output/index.html
