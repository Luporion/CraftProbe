// Pure scroll-state logic, intentionally independent from Terminal.Gui so it can be tested
// without a terminal/graphics driver and reused by other read-only log viewers.
internal sealed class ConsoleLogScrollState
{
    public bool AutoFollow { get; private set; } = true;
    private int _expectedY;
    private int _expectedHeight;
    private bool _hasApplied;

    public static int Bottom(int rows, int height) => Math.Max(0, rows - Math.Max(1, height));

    // Called before every refresh (and on ticks without fresh log lines). Any viewport
    // movement away from the last position set by CraftProbe is a user navigation action.
    public void ObserveViewport(int y, int height, int renderedRows)
    {
        if (!_hasApplied) return;
        if (height != _expectedHeight)
        {
            // Terminal resize is not the user manually scrolling away from the tail.
            _expectedHeight = height;
            _expectedY = Math.Min(_expectedY, Bottom(renderedRows, height));
            return;
        }
        if (y != _expectedY)
            AutoFollow = y >= Bottom(renderedRows, height);
        _expectedY = y;
    }

    // When the bounded log buffer discards old lines, preserve the same visible
    // logical line rather than jumping down. For filtered views, evictedRows counts
    // only rows that matched the active search/severity filter.
    public int AfterRefresh(int oldY, int height, int newRows, int evictedRows)
    {
        return AutoFollow ? Bottom(newRows, height)
            : Math.Clamp(oldY - Math.Max(0, evictedRows), 0, Bottom(newRows, height));
    }

    public void RecordApplied(int y, int height)
    {
        _hasApplied = true;
        _expectedY = y;
        _expectedHeight = height;
    }

    public int JumpToBottom(int rows, int height)
    {
        AutoFollow = true;
        return Bottom(rows, height);
    }

    public void Reset()
    {
        AutoFollow = true;
        _expectedY = 0;
        _expectedHeight = 0;
        _hasApplied = false;
    }
}
