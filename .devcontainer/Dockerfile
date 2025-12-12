FROM ubuntu:24.04

ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=$USER_UID

RUN set -eux; \
    # If UID/GID already exist (Ubuntu 24.04 ships with ubuntu:1000/1000), rename to requested user/group
    existing_user="$(getent passwd "${USER_UID}" | cut -d: -f1 || true)"; \
    existing_group="$(getent group  "${USER_GID}" | cut -d: -f1 || true)"; \
    if [ -n "${existing_group}" ] && [ "${existing_group}" != "${USERNAME}" ] && ! getent group "${USERNAME}" >/dev/null; then \
        groupmod -n "${USERNAME}" "${existing_group}"; \
    fi; \
    if [ -n "${existing_user}" ] && [ "${existing_user}" != "${USERNAME}" ] && ! id -u "${USERNAME}" >/dev/null 2>&1; then \
        usermod -l "${USERNAME}" "${existing_user}"; \
        usermod -d "/home/${USERNAME}" -m "${USERNAME}"; \
    fi; \
    # Ensure group exists (by name) and the user is on the intended UID/GID
    getent group "${USERNAME}" >/dev/null || groupadd --gid "${USER_GID}" "${USERNAME}"; \
    id -u "${USERNAME}" >/dev/null 2>&1 || useradd --uid "${USER_UID}" --gid "${USER_GID}" -m "${USERNAME}"; \
    usermod -u "${USER_UID}" "${USERNAME}"; \
    usermod -g "${USER_GID}" "${USERNAME}"; \
    \
    apt-get update; \
    apt-get install -y sudo; \
    rm -rf /var/lib/apt/lists/*; \
    echo "${USERNAME} ALL=(root) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}"; \
    chmod 0440 "/etc/sudoers.d/${USERNAME}"

USER $USERNAME
