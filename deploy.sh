#!/bin/sh

jekyll --no-auto
rsync -r -v _site/* sangjin@login.eecs.berkeley.edu:public_html/*
