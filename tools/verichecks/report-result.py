import os
import re
from github import Github, GithubException

print("Reporting result to Github actions")

token = os.environ['GITHUB_TOKEN']
gh = Github(token)

sha_env = os.environ['GITHUB_SHA']
repo_env = os.environ['GITHUB_REPOSITORY']

repo = gh.get_repo(repo_env)
commit = repo.get_commit(sha_env)

print(f"for repository {repo}, commit {commit}")

with open('build/Impl/Bundle.i.verified', 'r') as verified_file:
    verified_content = verified_file.read()

conclusion = 'neutral'
output_title = 'Complete'

try:
    overall = verified_content.splitlines()[0]
    overall_p = re.compile('^Overall: (Success|Fail)$')
    overall_outcome = overall_p.match(overall)[1]
    if overall_outcome == 'Fail':
        conclusion = 'failure'
        output_title = 'Failures'
    elif overall_outcome == 'Success':
        conclusion = 'success'
        output_title = 'Verified'
    else:
        conclusion = 'neutral'
except Exception:
    pass

wiki_build_path = f"https://raw.githubusercontent.com/wiki/vmware-labs/verified-betrfs/verichecks-results/{sha_env}"


cr_output = {
    'title': output_title,
    'summary': """
**Status** -- [svg]({}), [pdf]({}), [**error messages**]({})

**Summary**

```
{}
```

""".format(
        f'{wiki_build_path}/build/Impl/Bundle.i.status.svg',
        f'{wiki_build_path}/build/Impl/Bundle.i.status.pdf',
        f'{wiki_build_path}/build/Impl/Bundle.i.verified.err',
        verified_content,
    ),
}


repo.create_check_run(
    'status',
    head_sha=commit.sha,
    status='completed',
    external_id=f'{sha_env}-{repo_env}-status',
    conclusion=conclusion,
    output=cr_output,
)

