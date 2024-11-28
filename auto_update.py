name: Update NVIDIA GRID Driver

on:
  schedule:
    - cron: '0 0 * * *'  # Runs at 00:00 UTC every day
  workflow_dispatch:  # Allows manual trigger

jobs:
  update-drivers:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write

    steps:
      - uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: '3.x'

      - name: Install dependencies
        run: |
          python -m pip install --upgrade pip
          pip install ruamel.yaml requests

      - name: Update driver versions
        run: python auto_update.py

      - name: Check for changes
        id: git-check
        run: |
          git diff --exit-code driver_config.yml || echo "changes=true" >> $GITHUB_OUTPUT
          if [ -f new_version.txt ]; then
            echo "new_version=$(cat new_version.txt)" >> $GITHUB_OUTPUT
            rm new_version.txt  # Remove the temporary file
          fi

      - name: Create Pull Request
        if: steps.git-check.outputs.changes == 'true'
        uses: peter-evans/create-pull-request@v6
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          commit-message: 'chore: update NVIDIA GRID driver version to ${{ steps.git-check.outputs.new_version }}'
          title: 'chore: update NVIDIA GRID driver version to ${{ steps.git-check.outputs.new_version }}'
          body: |
            Automated PR to update NVIDIA GRID driver version to ${{ steps.git-check.outputs.new_version }}.
            
            This PR was automatically created by the NVIDIA driver update workflow.
          branch: update-nvidia-drivers-${{ steps.git-check.outputs.new_version }}
          delete-branch: true
          base: main