#!/bin/bash

# Based on the official Circle CI checkout script.

set -e

# always use https
git config --global url."https://github.com".insteadOf "ssh://git@github.com" || true
git config --global url."https://github.com/".insteadOf "git@github.com:" || true
git config --global gc.auto 0 || true

if [ -e '/home/circleci/project/.git' ] ; then
  echo 'Fetching into existing repository'
  existing_repo='true'
  cd '/home/circleci/project'
  git remote set-url origin "$CIRCLE_REPOSITORY_URL" || true
else
  echo 'Cloning git repository'
  existing_repo='false'
  mkdir -p '/home/circleci/project'
  cd '/home/circleci/project'
  git clone "$CIRCLE_REPOSITORY_URL" .
fi

if [ -n "$CIRCLE_TAG" ]; then
  echo 'Checking out tag'
  git checkout --force "$CIRCLE_TAG"
  git reset --hard "$CIRCLE_SHA1"
  git submodule update --init --recursive
else
  echo 'Checking out branch'
  git checkout --force -B "$CIRCLE_BRANCH" "$CIRCLE_SHA1"
  git --no-pager log --no-color -n 1 --format='HEAD is now at %h %s'
  git submodule update --init --recursive
fi
