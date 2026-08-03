"""
Build script that assembles an AWS Lambda deployment package (a zip file)
for the "AI Digital Twin" FastAPI application, ensuring that all Python
dependencies are compiled/installed for Lambda's actual runtime
environment rather than the developer's local machine.
Process:
1. Removes any previous build artifacts (`lambda-package/` directory and
   `lambda-deployment.zip`) to ensure a clean build.
2. Creates a fresh `lambda-package/` directory to stage all files that
   will be included in the deployment zip.
3. Installs dependencies from `requirements.txt` into `lambda-package/`
   using Docker, running the official AWS `public.ecr.aws/lambda/python:3.12`
   image with its entrypoint overridden, and forcing the `linux/amd64`
   platform and `manylinux2014_x86_64` wheel selection. This avoids the
   common pitfall of `pip install`-ing dependencies with native
   extensions (e.g. binary wheels) on a different OS/architecture (such
   as Windows, macOS, or WSL) than what Lambda actually runs, which can
   otherwise cause runtime import errors after deployment.
4. Copies the application's own source files (`server.py`,
   `lambda_handler.py`, `context.py`, `resources.py`) into the package
   directory, skipping any that don't exist.
5. Copies a `data/` directory (if present) into the package, for any
   bundled static/reference files the app needs at runtime.
6. Zips the entire `lambda-package/` directory into
   `lambda-deployment.zip`, preserving relative paths so that imports
   and file references resolve correctly once unpacked by Lambda.
7. Prints the final zip file size in megabytes, which is useful for
   checking against Lambda's package size limits (250 MB unzipped for
   direct upload, 50 MB zipped via the console).
Usage:
    python build_lambda_package.py
Requirements:
    - Docker must be installed and running, since dependency installation
      is performed inside a containerized Lambda-compatible environment
      rather than using the host machine's `pip` directly.
    - A `requirements.txt` file must be present in the current working
      directory.
"""
import os
import shutil
import zipfile
import subprocess


def main():
    """
    Build the Lambda deployment zip package.
    Cleans previous build artifacts, installs dependencies for the
    Lambda runtime via Docker, copies application source files and data,
    zips everything into `lambda-deployment.zip`, and prints the
    resulting file size.
    Raises:
        subprocess.CalledProcessError: If the Docker-based dependency
            installation step fails (e.g. Docker not running, invalid
            `requirements.txt`, or a package that can't be resolved for
            the target platform).
    """
    print("Creating Lambda deployment package...")

    # Clean up
    if os.path.exists("lambda-package"):
        shutil.rmtree("lambda-package")
    if os.path.exists("lambda-deployment.zip"):
        os.remove("lambda-deployment.zip")

    # Create package directory
    os.makedirs("lambda-package")

    # Install dependencies using Docker with Lambda runtime image
    print("Installing dependencies for Lambda runtime...")

    # Use the official AWS Lambda Python 3.12 image
    # This ensures compatibility with Lambda's runtime environment
    subprocess.run(
        [
            "docker",
            "run",
            "--rm",
            "--user", # Set the user to the current user to avoid permission errors 
            f"{os.getuid()}:{os.getgid()}", # Get the current user and group IDs
            "-v",
            f"{os.getcwd()}:/var/task",
            "--platform",
            "linux/amd64",  # Force x86_64 architecture
            "--entrypoint",
            "",  # Override the default entrypoint
            "public.ecr.aws/lambda/python:3.12",
            "/bin/sh",
            "-c",
            "pip install --target /var/task/lambda-package -r /var/task/requirements.txt --platform manylinux2014_x86_64 --only-binary=:all: --upgrade",
        ],
        check=True,
    )

    # Copy application files
    print("Copying application files...")
    for file in ["server.py", "lambda_handler.py", "context.py", "resources.py"]:
        if os.path.exists(file):
            shutil.copy2(file, "lambda-package/")
    
    # Copy data directory
    if os.path.exists("data"):
        shutil.copytree("data", "lambda-package/data")

    # Create zip
    print("Creating zip file...")
    with zipfile.ZipFile("lambda-deployment.zip", "w", zipfile.ZIP_DEFLATED) as zipf:
        for root, dirs, files in os.walk("lambda-package"):
            for file in files:
                file_path = os.path.join(root, file)
                arcname = os.path.relpath(file_path, "lambda-package")
                zipf.write(file_path, arcname)

    # Show package size
    size_mb = os.path.getsize("lambda-deployment.zip") / (1024 * 1024)
    print(f"✓ Created lambda-deployment.zip ({size_mb:.2f} MB)")


if __name__ == "__main__":
    main()