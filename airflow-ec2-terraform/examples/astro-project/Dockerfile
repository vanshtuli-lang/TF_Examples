# Your Airflow image: the Runtime base plus your Python and OS packages.
# Build it in your pipeline (security scan, push to your registry), then set
# airflow_image to the pushed image, pinned by digest. Use your registry's copy
# of the base image if quay.io is not reachable.
FROM quay.io/astronomer/astro-runtime:3.4-1-chainguard
