package detect

import (
	"reflect"
	"testing"
)

func TestHardExclusionsDropSilently(t *testing.T) {
	kept, soft := SplitExclusions([]string{
		"package.json",
		"node_modules/left-pad/package.json",
		"a/vendor/pkg/composer.json",
		".git/config",
		"bower_components/x/bower.json",
	}, nil)
	if want := []string{"package.json"}; !reflect.DeepEqual(kept, want) {
		t.Errorf("kept = %v, want %v", kept, want)
	}
	if len(soft) != 0 {
		t.Errorf("hard-excluded paths must not surface as soft, got %v", soft)
	}
}

func TestAFileNamedLikeAnExcludedDirectorySurvives(t *testing.T) {
	// The exclusion names directories: the bash regex was (^|/)(name)/, so a
	// plain file called vendor is not under a vendor/ directory.
	kept, _ := SplitExclusions([]string{"vendor", "docs/build"}, nil)
	if want := []string{"vendor", "docs/build"}; !reflect.DeepEqual(kept, want) {
		t.Errorf("kept = %v, want %v", kept, want)
	}
}

func TestSoftExclusionsAreReturnedSeparately(t *testing.T) {
	kept, soft := SplitExclusions([]string{
		"package.json",
		"examples/demo/package.json",
		"dist/package.json",
		"docs/fixtures/tree/package.json",
	}, nil)
	if want := []string{"package.json"}; !reflect.DeepEqual(kept, want) {
		t.Errorf("kept = %v, want %v", kept, want)
	}
	wantSoft := []string{
		"examples/demo/package.json",
		"dist/package.json",
		"docs/fixtures/tree/package.json",
	}
	if !reflect.DeepEqual(soft, wantSoft) {
		t.Errorf("soft = %v, want %v", soft, wantSoft)
	}
}

func TestIncludeReadmitsASoftExcludedName(t *testing.T) {
	kept, soft := SplitExclusions([]string{
		"examples/demo/package.json",
		"dist/package.json",
	}, []string{"examples"})
	if want := []string{"examples/demo/package.json"}; !reflect.DeepEqual(kept, want) {
		t.Errorf("kept = %v, want %v", kept, want)
	}
	if want := []string{"dist/package.json"}; !reflect.DeepEqual(soft, want) {
		t.Errorf("soft = %v, want %v", soft, want)
	}
}

func TestIncludeNeverReadmitsAHardExclusion(t *testing.T) {
	kept, _ := SplitExclusions([]string{"node_modules/x/package.json"}, []string{"node_modules"})
	if len(kept) != 0 {
		t.Errorf("hard exclusions are not negotiable, kept = %v", kept)
	}
}

func TestExampleAndExamplesAreDistinctNames(t *testing.T) {
	// Both are on the soft list; --include of one must not readmit the other.
	kept, soft := SplitExclusions([]string{
		"example/package.json",
		"examples/package.json",
	}, []string{"example"})
	if want := []string{"example/package.json"}; !reflect.DeepEqual(kept, want) {
		t.Errorf("kept = %v, want %v", kept, want)
	}
	if want := []string{"examples/package.json"}; !reflect.DeepEqual(soft, want) {
		t.Errorf("soft = %v, want %v", soft, want)
	}
}

func TestSegmentMatchIsExact(t *testing.T) {
	// "distribution" contains "dist" but is not the segment "dist".
	kept, soft := SplitExclusions([]string{"distribution/package.json"}, nil)
	if want := []string{"distribution/package.json"}; !reflect.DeepEqual(kept, want) {
		t.Errorf("kept = %v, want %v", kept, want)
	}
	if len(soft) != 0 {
		t.Errorf("soft = %v, want empty", soft)
	}
}
