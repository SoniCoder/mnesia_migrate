PROJECT = mnesia_migrate
PROJECT_DESCRIPTION = An application to upgrade or downgrade mnesia database
PROJECT_VERSION = 0.0.1

DEPS = uuid erlydtl

dep_uuid = git https://bitbucket.org/gorcode/erlang-uuid.git 91df746
dep_erlydtl = git https://github.com/erlydtl/erlydtl f8602ca664

include erlang.mk
