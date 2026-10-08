local syntax = require "core.syntax"

syntax.add {
  files = {
    "^Containerfile[%.%w_-]*$", "[/\\]Containerfile[%.%w_-]*$",
    "^Dockerfile[%.%w_-]*$", "[/\\]Dockerfile[%.%w_-]*$",
    "%.containerfile$", "%.dockerfile$",
  },
  comment = "#",
  patterns = {
    { pattern = "#.*\n",                          type = "comment"  },
    { pattern = { '"', '"', '\\' },               type = "string"   },
    { pattern = { "'", "'", '\\' },               type = "string"   },
    { pattern = "%${[%w_:%-]*}",                  type = "keyword2" },
    { pattern = "%$[%a_][%w_]*",                  type = "keyword2" },
    { pattern = "%-%-[%w%-]+",                    type = "operator" },
    { pattern = "%d+%.?%d*",                      type = "number"   },
    { pattern = "[%a_][%w_]*",                    type = "symbol"   },
  },
  symbols = {
    ["FROM"] = "keyword", ["AS"] = "keyword", ["RUN"] = "keyword", ["CMD"] = "keyword",
    ["LABEL"] = "keyword", ["MAINTAINER"] = "keyword", ["EXPOSE"] = "keyword",
    ["ENV"] = "keyword", ["ADD"] = "keyword", ["COPY"] = "keyword",
    ["ENTRYPOINT"] = "keyword", ["VOLUME"] = "keyword", ["USER"] = "keyword",
    ["WORKDIR"] = "keyword", ["ARG"] = "keyword", ["ONBUILD"] = "keyword",
    ["STOPSIGNAL"] = "keyword", ["HEALTHCHECK"] = "keyword", ["SHELL"] = "keyword",
  },
}
