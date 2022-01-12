# Dockerfile for ASHS (fast-ashs) version
FROM pyushkevich/itksnap:v3.8.2

# Descriptor fields
LABEL version="fastashs-1.0.0"
LABEL maintainer="pyushkevich@gmail.com"
LABEL description="ASHS-T1 base image"

# Make sure we have git, curl and other basics
RUN apt-get update
RUN apt-get install -y curl git parallel imagemagick

# Set the working directory for the ASHS app
WORKDIR /app

# Download the current build of ASHS
COPY ./ashs /app/

# Copy the current scriptlet
COPY . /app/


