# Pull a pre-built alpine docker image with nginx and python3 installed
FROM python:slim-bookworm

ARG DEBIAN_FRONTEND=noninteractive

ENV LISTEN_PORT=8000
EXPOSE 8000

ENV STATIC_URL=/app/hack_console/static

# Set the folder where uwsgi looks for the app
WORKDIR /app

# Copy the app contents to the image
COPY . /app

# installing python packages - requirements.txt
COPY requirements.txt /
RUN pip install --no-cache-dir -U pip
RUN pip install --no-cache-dir -r /requirements.txt

CMD /app/startup.sh