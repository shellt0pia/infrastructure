from ansible.errors import AnsibleFilterError
import subprocess

SYSTEMD_ESCAPE = 'systemd-escape'

def systemd_escape(s,
        suffix=None,
        template=None,
        path=False,
        mangle=False):
    cmd = []
    cmd.append(SYSTEMD_ESCAPE)

    # If any two options are truthy.
    if suffix and (template or mangle) or (template and mangle):
        raise AnsibleFilterError("Options suffix, template, and mangle are mutually exclusive.")

    if suffix:
        cmd.append("--suffix={}".format(suffix))
    elif template:
        cmd.append("--template={}".format(template))
    elif mangle:
        cmd.append("--mangle")

    if path:
        cmd.append("--path")

    cmd.append(s)

    try:
        res = subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True).rstrip('\n')
    except Exception as e:
        raise AnsibleFilterError('Error in subprocess.check_output in systemd_escape filter plugin:\n%s' % e)

    return res

def systemd_unescape(s,
        path=False,
        instance=False):

    cmd = []
    cmd.append(SYSTEMD_ESCAPE)
    cmd.append('-u')

    if path:
        #This won't work because it will add the quote in the path.
        cmd.append("--path")

    if instance:
        cmd.append("--instance")

    cmd.append(s)

    try:
        res = subprocess.check_output(cmd, text=True).rstrip('\n')
    except Exception as e:
        raise AnsibleFilterError('Error in subprocess.check_output in systemd_escape filter plugin:\n%s' % e)

    return res

class FilterModule(object):
    def filters(self):
        return {
            'systemd_escape': systemd_escape,
            'systemd_unescape': systemd_unescape
        }
