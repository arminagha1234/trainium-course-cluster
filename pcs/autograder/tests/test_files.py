"""
test_files.py — verify the student actually uploaded the expected file.

Weight 0: this does not award points, it just gives the student a clear, early
signal if they uploaded the wrong file (e.g. a zip, or a differently named
kernel) before the correctness/performance tests report a confusing failure.
Kept separate from test_kernel_result.py to avoid duplicating the file check.

gradescope_utils.check_submitted_files() looks under /autograder/submission by
default, which is where Gradescope drops the upload — the same file
run_autograder scps to the cluster as student.py.
"""

import unittest

from gradescope_utils.autograder_utils.decorators import weight
from gradescope_utils.autograder_utils.files import check_submitted_files


class SubmittedFilesTest(unittest.TestCase):
    @weight(0)
    def test_submitted_files(self):
        """The submission must include student.py."""
        missing = check_submitted_files(["student.py"])
        for path in missing:
            print("Missing required file: {}".format(path))
        self.assertEqual(
            len(missing), 0,
            "missing required submission file(s): {}".format(", ".join(missing)),
        )
