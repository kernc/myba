#!/bin/sh

mkdir -p output
cp icon.svg output

preamble='<!doctype html>
<html lang=en vocab="https://schema.org/" typeof="SoftwareApplication">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Myba - git-based file backup with encryption</title>
<link rel="logo icon" href="icon.svg">
<meta name="theme-color" content="#333">
<meta property="name" content="myba">
<meta property="applicationCategory" content="BusinessApplication"><meta property="applicationCategory" content="DeveloperApplication"><meta property="applicationCategory" content="SecurityApplication"><meta property="applicationCategory" content="UtilitiesApplication">
<meta property="operatingSystem" content="Linux"><meta property="operatingSystem" content="macOS"><meta property="operatingSystem" content="Windows">
<meta property="isAccessibleForFree" content="true">
<link property="license" href="https://www.gnu.org/licenses/agpl-3.0.txt">
<link property="sameAs" href="https://github.com/kernc/myba/">
<meta property="url" content="./">
<script async src="https://www.googletagmanager.com/gtag/js?id=G-JT9W3RXCJD"></script>
<script>window.dataLayer=window.dataLayer||[];function gtag(){dataLayer.push(arguments);}gtag("js",new Date());gtag("config","G-JT9W3RXCJD");</script>
<style>
html{background:DarkOliveGreen; line-height: 1.4em; font-family:sans-serif;}
article {background:#fffb; padding:2em; margin:auto; max-width: 900px;}
pre {background:#fff8;}
code:not(pre code) {background:#fff8; padding: .2em .5em; white-space: nowrap;}
ul li code:not(pre code):first-child {font-weight: bold;}
h1,h2,h3,h4 {margin-top: 2em}
h1 img {vertical-align: middle; margin: 0 1em 1em 0;}
h1 {line-height: 1.3em;}
a:link {color:navy}
a:hover {color:blue !important}
a:visited {color:#230}
summary {width:fit-content; border:2px solid silver; cursor:pointer; padding:.2em .6em; margin:.3em 0}
details[open] summary {border:2px solid black;}
</style>
<meta property="og:title" content="Myba - git-based file backup with encryption">
<meta property="og:type" content="website">
<meta property="og:url" content="https://kernc.github.io/myba/">
<meta property="og:image" content="https://kernc.github.io/myba/icon.svg">
<script async src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.10.0/highlight.min.js" integrity="sha512-6yoqbrcLAHDWAdQmiRlHG4+m0g/CT/V9AGyxabG8j7Jk8j3r3K6due7oqpiRMZqcYe9WM2gPcaNNxnl2ux+3tA==" crossorigin></script>
<link rel="stylesheet preload" as="style" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.10.0/styles/github-dark.min.css" integrity="sha512-rO+olRTkcf304DQBxSWxln8JXCzTHlKnIdnMUwYvQa9/Jd4cQaNkItIUj6Z4nvW1dqK0SKXLbn9h4KwZTNtAyw==" crossorigin>
<link rel="preconnect" href="https://www.gstatic.com/">
<link rel="preconnect" href="https://ssl.gstatic.com/">
<link rel="preconnect" href="https://fonts.gstatic.com/">
<link rel="preconnect" href="https://ajax.googleapis.com/">
<link rel="preconnect" href="https://fonts.googleapis.com/">
<link rel="preconnect" href="https://www.google.com/">
</head>
<body><main><article>
'
postamble='</article></main>
<div property="aggregateRating" typeof="AggregateRating"><meta property="reviewCount" content="1"><meta property="ratingValue" content="5"></div>
<div property="offers" typeof="Offer"><meta property="price" content="0"><meta property="priceCurrency" content="BTC"></div>
<script>addEventListener("load", () => hljs.highlightAll());</script>
<script>[...document.links].forEach(a => { if (a.hostname !== location.hostname) a.target = "_blank"; })</script>
</body></html>'

ext_config_file="$(dirname "$0")/markdown-ext-config.json"
{
    echo "$preamble"
    python -m markdown -v -o html -x extra -x toc -c "$ext_config_file" README.full.md
    echo "$postamble"
} > output/index.html
