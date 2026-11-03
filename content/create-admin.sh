#!/bin/sh
set -eu

# Shynet ships a `registeradmin` command, but it invents its own random password
# and only prints it to stdout, where the person who just installed the app will
# never see it. Instead: run the migrations, then create (or repair) the admin
# account with the address and password supplied as deploy parameters.
#
# Everything here is idempotent -- rerunning the container must not disturb an
# account whose password the operator may already have changed.

cd /usr/src/shynet

# Wait for the database to accept connections before touching the schema.
i=0
until python manage.py migrate --noinput >/tmp/migrate.log 2>&1; do
  i=$((i + 1))
  if [ "${i}" -ge 30 ]; then
    echo "shynet: migrations failed after ${i} attempts" >&2
    cat /tmp/migrate.log >&2 || true
    exit 1
  fi
  echo "shynet: waiting for database (attempt ${i})"
  sleep 2
done

export ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
export ADMIN_PASSWORD="${ADMIN_PASSWORD:?ADMIN_PASSWORD is required}"

python manage.py shell -c "
import os
import uuid
from django.contrib.auth.hashers import make_password
from core.models import User
email = os.environ['ADMIN_EMAIL']
pwd = os.environ['ADMIN_PASSWORD']
user = User.objects.filter(email=email).first()
if user is None:
    User.objects.create_superuser(str(uuid.uuid4()), email=email, password=pwd)
    print('shynet: created admin ' + email)
else:
    # Keep the operator's chosen password working across restarts. set_password
    # exists on AbstractUser but is not guaranteed across forks, so fall back to
    # assigning a hash directly.
    setter = getattr(user, 'set_password', None)
    if callable(setter):
        setter(pwd)
    else:
        user.password = make_password(pwd)
    user.save()
    print('shynet: admin exists, password synced')
"

# Hand over to the normal Shynet startup (its own db setup is already done).
exec ./webserver.sh
